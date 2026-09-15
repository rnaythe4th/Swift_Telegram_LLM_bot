import Foundation

/// The database schema, versioned and applied by the bot itself.
///
/// Two rules make this safe to run on every boot:
///
/// 1. **A newer database refuses an older binary.** `bot_schema_meta.version`
///    is compared with `PostgresSchema.version` before anything is read; a
///    database written by a newer build makes the process exit with a sentence
///    that says so, instead of writing rows the new columns do not expect.
/// 2. **Steps are idempotent and ordered.** Every statement is
///    `create … if not exists` / `add column if not exists`, so applying step N
///    twice is the same as applying it once, and a crash halfway through a
///    migration is repaired by the next boot.
///
/// The whole thing is embedded rather than shipped as `.sql` files: a migration
/// the binary cannot see is a migration that will not run on the machine that
/// needs it.
enum PostgresSchema {
    /// Bump this, and add a step, whenever the schema changes.
    static var version: Int { steps.count }

    /// One migration step. `index` is its version number (1-based); the
    /// database records the highest one applied.
    struct Step: Sendable {
        let index: Int
        let statements: [String]
    }

    static var steps: [Step] {
        [Step(index: 1, statements: initialSchema)]
    }

    /// Applied before anything else, including the version check itself.
    static let metaTable = """
        create table if not exists bot_schema_meta (
            id         integer     primary key default 1 check (id = 1),
            version    integer     not null,
            applied_at timestamptz not null default now()
        )
        """

    // MARK: - v1

    private static let initialSchema: [String] = [
        // ---- People ---------------------------------------------------------
        // Every per-person table points here, so `on delete cascade` can clean
        // up after a forget request without leaving orphans behind.
        //
        // Whether the bot can reach someone in a DM is deliberately *not* here:
        // it is a property of the chat, and it lives in `bot_chat`
        // (`type = 'private'` plus `bot_removed`). A column here would be a
        // second answer to the same question, and the one nobody writes.
        """
        create table if not exists bot_user (
            user_key        text        primary key,
            user_id         bigint      unique,
            username        text,
            first_name      text,
            first_seen_at   timestamptz not null default now(),
            seen_at         timestamptz not null default now()
        )
        """,
        "create index if not exists bot_user_username_idx on bot_user (lower(username))",
        "create index if not exists bot_user_seen_at_idx on bot_user (seen_at)",

        // ---- Money ----------------------------------------------------------
        // `check (balance_nanos >= 0)` is the point of this table: a wallet
        // cannot go negative through a bug in Swift, because Postgres will not
        // accept the row. Amounts are nanodollars (see `Money`).
        """
        create table if not exists bot_wallet (
            user_key           text        primary key,
            balance_nanos      bigint      not null default 0 check (balance_nanos >= 0),
            topped_up_nanos    bigint      not null default 0 check (topped_up_nanos >= 0),
            spent_billed_nanos bigint      not null default 0,
            spent_real_nanos   bigint      not null default 0,
            lapsed_notice_at   timestamptz,
            updated_at         timestamptz not null default now()
        )
        """,
        """
        create index if not exists bot_wallet_lapsed_idx
            on bot_wallet (topped_up_nanos, lapsed_notice_at)
            where topped_up_nanos > 0
        """,

        // Append-only history of every movement. Without it "почему у меня было
        // $2, а стало $1.30" has no answer anywhere — not for the user, not for
        // the owner, not even in the logs.
        """
        create table if not exists bot_ledger (
            id                  bigserial   primary key,
            user_key            text        not null,
            kind                text        not null,
            amount_nanos        bigint      not null,
            balance_after_nanos bigint      not null,
            ref                 text,
            created_at          timestamptz not null default now()
        )
        """,
        "create index if not exists bot_ledger_user_idx on bot_ledger (user_key, id desc)",

        // Payment idempotency as a constraint rather than a capped list in
        // memory. `insert … on conflict do nothing returning` makes "check then
        // claim" one statement, so two deliveries of one payment cannot both win
        // — across coroutines or across processes.
        """
        create table if not exists bot_payment (
            idempotency_key text        primary key,
            user_key        text        not null,
            purpose         text        not null,
            amount_cents    integer,
            chat_id         bigint      not null,
            method          text        not null,
            processed_at    timestamptz not null default now()
        )
        """,
        "create index if not exists bot_payment_user_idx on bot_payment (user_key, processed_at desc)",

        // Idempotency for money that is not a payment: referral payouts, and
        // anything later that must credit a wallet exactly once. The primary
        // key *is* the guarantee — checking a flag in memory and then writing
        // is two steps, and a crash between them pays twice.
        """
        create table if not exists bot_claim (
            key        text        primary key,
            created_at timestamptz not null default now()
        )
        """,

        // ---- Tenants and access ---------------------------------------------
        // `paid_until` and the winback discount are written only inside a money
        // transaction; every other column is write-behind. They never collide
        // because each writer names its own columns in `do update set`.
        """
        create table if not exists bot_tenant (
            user_key            text        primary key,
            owner_username      text        not null,
            paid_until          timestamptz,
            default_model       text        not null,
            default_role        text        not null,
            default_history     integer     not null,
            presets             jsonb       not null default '{}'::jsonb,
            licences            jsonb       not null default '{}'::jsonb,
            usage               jsonb       not null default '{}'::jsonb,
            notice_cycle_until  timestamptz,
            sent_notices        text[]      not null default '{}',
            winback_percent     integer,
            winback_expires_at  timestamptz,
            reminders_opt_out   boolean     not null default false,
            created_at          timestamptz not null default now(),
            updated_at          timestamptz not null default now()
        )
        """,
        """
        create index if not exists bot_tenant_paid_until_idx
            on bot_tenant (paid_until) where paid_until is not null
        """,

        // ---- Chats ------------------------------------------------------------
        """
        create table if not exists bot_chat (
            chat_id     bigint      primary key,
            type        text,
            title       text,
            username    text,
            first_name  text,
            owner_key   text,
            bot_removed boolean     not null default false,
            updated_at  timestamptz not null default now()
        )
        """,
        "create index if not exists bot_chat_owner_idx on bot_chat (owner_key) where owner_key is not null",

        // The conversation itself stays a document: it is always read and
        // written whole, and nothing is ever searched inside it.
        """
        create table if not exists bot_chat_context (
            chat_id    bigint      not null,
            thread_id  bigint      not null default 0,
            data       jsonb       not null,
            updated_at timestamptz not null default now(),
            primary key (chat_id, thread_id)
        )
        """,
        "create index if not exists bot_chat_context_updated_idx on bot_chat_context (updated_at)",

        """
        create table if not exists bot_invite (
            token      text        primary key,
            owner_key  text        not null,
            created_at timestamptz not null default now()
        )
        """,
        "create index if not exists bot_invite_owner_idx on bot_invite (owner_key)",

        // ---- Free-tier allowance ---------------------------------------------
        // Persisted on purpose: an in-memory counter hands everyone a fresh
        // allowance on every redeploy, and the allowance is the main conversion
        // driver.
        """
        create table if not exists bot_premium_usage (
            subject text    primary key,
            day     integer not null,
            used    integer not null default 0
        )
        """,
        "create index if not exists bot_premium_usage_day_idx on bot_premium_usage (day)",

        // ---- Growth ----------------------------------------------------------
        """
        create table if not exists bot_referral (
            invited_user_id bigint      primary key,
            inviter_user_id bigint      not null,
            bound_at        timestamptz not null default now(),
            rewarded_at     timestamptz,
            paid_bonus_at   timestamptz,
            data            jsonb       not null
        )
        """,
        "create index if not exists bot_referral_inviter_idx on bot_referral (inviter_user_id)",

        // Aggregates live in their own table because they outlive the records
        // they came from: pruning attributions must never reset an inviter's
        // reward cap or their count of paying friends.
        """
        create table if not exists bot_referral_tally (
            inviter_user_id bigint primary key,
            data            jsonb  not null
        )
        """,

        """
        create table if not exists bot_traffic_attribution (
            user_id      bigint      primary key,
            tag          text        not null,
            joined_at    timestamptz not null default now(),
            activated_at timestamptz,
            paid_at      timestamptz,
            payments     integer     not null default 0
        )
        """,
        "create index if not exists bot_traffic_tag_idx on bot_traffic_attribution (tag)",

        """
        create table if not exists bot_funnel_daily (
            day   integer not null,
            event text    not null,
            count bigint  not null default 0,
            primary key (day, event)
        )
        """,

        // ---- Payments in flight ----------------------------------------------
        """
        create table if not exists bot_crypto_invoice (
            id         text        primary key,
            owner_key  text        not null,
            status     text        not null,
            expires_at timestamptz not null,
            data       jsonb       not null
        )
        """,
        "create index if not exists bot_crypto_invoice_status_idx on bot_crypto_invoice (status, expires_at)",

        // `vendor_payment_id unique` is the second dedup ring behind
        // `bot_payment`: the aggregator retries its callback until acknowledged.
        """
        create table if not exists bot_external_order (
            id                text        primary key,
            payer_key         text        not null,
            status            text        not null,
            expires_at        timestamptz not null,
            vendor_payment_id text        unique,
            data              jsonb       not null
        )
        """,

        // ---- Documents --------------------------------------------------------
        """
        create table if not exists bot_config (
            key        text        primary key,
            data       jsonb       not null,
            updated_at timestamptz not null default now()
        )
        """,
    ]
}

enum PostgresSchemaError: LocalizedError {
    case databaseNewerThanBinary(database: Int, binary: Int)

    var errorDescription: String? {
        switch self {
        case .databaseNewerThanBinary(let database, let binary):
            return """
                Database schema is version \(database); this build only knows version \(binary). \
                Refusing to start: an older binary writing into a newer schema loses whatever \
                the new columns hold. Deploy the newer build, or restore a matching backup.
                """
        }
    }
}
