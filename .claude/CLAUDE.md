## basics
This is telegram chat bot written in Swift server and placed inside docker container.
Main functionality:
- Recieve telegram updates and respond to user messages with Ai using API requests.
- Has memory for every chat, that contains history of messages, settings of model, reasoning, history length and other.
- Parameters can be changed via commands or bot UI menu.
- Bot state is backuped to Supabase.

## tenant system
Bot feautures free plan that allows to use only free models. To access paid model i want users to make a payment using telegram stars or crypto.
The final version (wich we are building) must have:
- Superadmins (default @maythe4th) that can control everything and they are real owners and creators of this bot.
- Regular users, they can be in a group chat with this bot or talk to it in private messages. They have access only to free models, unless licence owner given permission for this group chat or private chat to use paid models. Regular users can add per-chat presets for bot parametr to quickly change something without typing the entire command.
- Admins aka licence owner who paid to access paid features. They can't do superadmins things like set bot's price, set default on-start presets and private things like that. But they have their virtual copy of bot and can tell him which chat or group has access to paid models. Also admins can edit global presets for parameters (regular users can't) and edit per-chat presets.
- Superadmins have all Admin capabilities.
- Admins can open their control panel inside some chat and press button to quickly add or remove this chat to his licence. Only admins can do that.

Only @maythe4th can add another Superadmin or remove.

## tenant licensing system
Users who paid required amount become Admins (not Superadmins). Now then can add it to group chat and it will automatically assign this chat to his licence and this chat will recieve access to paid models. Or, if the bot already was in some group chat, Admin can manually assign the chat to his licence by entering chat ID, giving this chat access to paid models. The same for private chat: admin enter @username and grants this user access to paid models.
- Admins have controls of chats that use his licence. They can remove or manually add chats to this list.
- Superadmins have controls for all Admins and their chats. Superadmins have statistics for every Admin and their chats like total tokenes burned by them and COST in $.

## tenant pricing
- Subscription to access paid models.
- Superadmin sets price and payment methods.
