extension ChatContextStore {
    func mainMenuEntries(for audience: MainMenuAudience) -> [MainMenuEntry] {
        mainMenuConfig.entries(for: audience)
    }

    func editMainMenu(_ edit: MainMenuEdit, button: MainMenuButton?, audience: MainMenuAudience, by invoker: UserKey) -> Bool {
        guard isSuperAdmin(invoker), mainMenuConfig.apply(edit, to: button, for: audience) else { return false }
        dirtyConfigs.insert(.mainMenu)
        return true
    }
}
