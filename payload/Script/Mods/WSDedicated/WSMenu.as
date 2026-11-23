// WitchspireDedicatedServer - "Join Dedicated Server" main-menu entry and dialog.
//
// Built entirely from the game's own widgets so it looks native:
//   * the main-menu entry is the game's own (normally hidden) "Join Game" button, relabelled
//   * the dialog is the game's "Create New World" modal, re-purposed: its name box becomes the server
//     address, its Difficulty row becomes Port (a second text box of the same native class and style),
//     its Create button becomes Join, and its disclaimer panel explains dedicated servers.
//
// Joining: a dedicated server is reached over a direct IP link, which Epic Online Services refuses
// while signed in. The dialog therefore signs out of EOS first, connects, and the main menu signs back
// in automatically afterwards. The character on the server is tied to the player's SteamID.

namespace WSMenu
{
    const int DefaultPort = 7777;

    // ---- Diagnostics (-WSDumpUI): log a widget hierarchy with classes, names and texts ----
    void Dump(UWidget Widget, int Depth)
    {
        if (Widget == nullptr)
            return;
        FString Indent;
        for (int i = 0; i < Depth; i++)
            Indent += "  ";

        FString Extra;
        UTextBlock Text = Cast<UTextBlock>(Widget);
        if (Text != nullptr)
            Extra = f" text='{Text.GetText()}'";
        UEditableTextBox Box = Cast<UEditableTextBox>(Widget);
        if (Box != nullptr)
            Extra = f" box='{Box.GetText()}'";
        UFoundationButtonBase Button = Cast<UFoundationButtonBase>(Widget);
        if (Button != nullptr)
            Extra = f" button='{Button.GetText()}'";
        const FString Visible = f"{Widget.GetVisibility()}";
        WSDS::Info(f"UI {Indent}{Widget.Class.GetName()} '{Widget.GetName()}' vis={Visible}{Extra}");

        UUserWidget User = Cast<UUserWidget>(Widget);
        if (User != nullptr && Depth > 0 && Depth < 12)
        {
            if (Button == nullptr)
                Dump(User.GetRootWidget(), Depth + 1);
            return;
        }

        UPanelWidget Panel = Cast<UPanelWidget>(Widget);
        if (Panel != nullptr)
        {
            for (int i = 0; i < Panel.GetChildrenCount(); i++)
                Dump(Panel.GetChildAt(i), Depth + 1);
        }
    }

    void DumpUserWidget(UUserWidget Widget, const FString& Label)
    {
        WSDS::Info(f"UI ===== {Label}: {Widget.Class.GetName()} =====");
        Dump(Widget.GetRootWidget(), 1);
    }

    TSubclassOf<UCreateWorldModalWidget> GetCreateWorldModalClass(TSubclassOf<UStartGameWidget> StartGameClass)
    {
        TSubclassOf<UCreateWorldModalWidget> Result;
        if (!StartGameClass.IsValid())
            return Result;
        UStartGameWidget StartGame = Cast<UStartGameWidget>(StartGameClass.Get().GetDefaultObject());
        if (StartGame != nullptr)
            Result = StartGame.CreateWorldWidgetModalClass;
        return Result;
    }

    // Called from UMainMenuWidget::OnInitialized.
    void SetupMainMenu(UMainMenuWidget Menu, UCommonButtonBase JoinButton, TSubclassOf<UStartGameWidget> StartGameClass)
    {
        UWSMenuSubsystem MenuSubsystem = UWSMenuSubsystem::Get();
        if (MenuSubsystem != nullptr)
            MenuSubsystem.InitMainMenu(Menu, JoinButton, GetCreateWorldModalClass(StartGameClass));

        if (System::ParseParam(System::GetCommandLine(), "WSDumpUI"))
            DumpUserWidget(Menu, "Main menu");
    }

    FString SanitizePlayerName(const FString& Raw)
    {
        FString Name = Raw.Replace("?", "").Replace("=", "").Replace("#", "").Replace(" ", "_").Left(20);
        return Name.IsEmpty() ? "Witch" : Name;
    }
}

// Remembers the last server the player joined.
UCLASS()
class UWSJoinSettingsSave : USaveGame
{
    UPROPERTY()
    FString Address = "";

    UPROPERTY()
    int Port = 7777;
};

UCLASS()
class UWSMenuSubsystem : UScriptWorldSubsystem
{
    const FString SettingsSlot = "WSJoinSettings";

    private TSubclassOf<UCreateWorldModalWidget> DialogClass;
    private UCommonActivatableWidget Dialog;
    private UEditableTextBox AddressBox;
    private UEditableTextBox PortBox;
    private UEditableTextBox PasswordBox;
    private USizeBox PortSlot;
    private bool bSyncFieldWidth = false;
    private UCommonActivatableWidgetSwitcher DialogSwitcher;
    private UCommonTextBlock StatusText;
    private UFoundationButtonBase JoinDialogButton;

    // Join flow state
    private FString PendingUrl;
    private bool bWaitingForLogout = false;
    private float LogoutWaited = 0;

    void InitMainMenu(UMainMenuWidget Menu, UCommonButtonBase JoinButton, TSubclassOf<UCreateWorldModalWidget> InDialogClass)
    {
        DialogClass = InDialogClass;

        // Back on the main menu after a dedicated-server session: sign back in to EOS.
        UWSClientStateSubsystem ClientState = UWSClientStateSubsystem::Get();
        if (ClientState != nullptr && ClientState.bSignedOutForDedicated)
        {
            ClientState.bSignedOutForDedicated = false;
            UOnlineIdentitySubsystem Identity = UOnlineIdentitySubsystem::Get();
            if (Identity != nullptr && Identity.GetLoginStatus(0) != EOnlineLoginStatus::LoggedIn)
            {
                WSDS::Info("Menu: signing back in to Epic Online Services after a dedicated-server session");
                UOnlineIdentitySubsystemAutoLogin Login = UOnlineIdentitySubsystemAutoLogin::AutoLogin(Identity, 0);
                if (Login != nullptr)
                    Login.Activate();
            }
        }

        if (JoinButton == nullptr || !DialogClass.IsValid())
        {
            WSDS::Info("Menu: Join Dedicated Server entry unavailable (menu layout changed?)");
            return;
        }

        JoinButton.OnButtonBaseClicked.Clear();
        JoinButton.OnButtonBaseClicked.AddUFunction(this, n"OnMenuButtonClicked");
        UFoundationButtonBase Label = Cast<UFoundationButtonBase>(JoinButton);
        if (Label != nullptr)
            Label.SetText(FText::FromString("Join Dedicated Server"));
        JoinButton.SetVisibility(ESlateVisibility::SelfHitTestInvisible);
    }

    UFUNCTION()
    private void OnMenuButtonClicked(UCommonButtonBase Button)
    {
        OpenDialog();
    }

    private UWidget Find(UUserWidget Owner, FName WidgetName)
    {
        UWidget Found = Owner.GetWidgetFromName(WidgetName);
        if (Found == nullptr)
            WSDS::Info(f"Menu: dialog widget '{WidgetName}' not found");
        return Found;
    }

    private void SetLabel(UUserWidget Owner, FName WidgetName, const FString& Text)
    {
        UTextBlock Block = Cast<UTextBlock>(Find(Owner, WidgetName));
        if (Block != nullptr)
            Block.SetText(FText::FromString(Text));
    }

    private UEditableTextBox CloneTextBox(UEditableTextBox Source)
    {
        UEditableTextBox Box = Cast<UEditableTextBox>(NewObject(Dialog, Source.Class));
        Box.SetWidgetStyle(Source.WidgetStyle);
        UHercEditableTextBox SourceHerc = Cast<UHercEditableTextBox>(Source);
        UHercEditableTextBox BoxHerc = Cast<UHercEditableTextBox>(Box);
        if (SourceHerc != nullptr && BoxHerc != nullptr)
        {
            BoxHerc.bOpenGamepadInputOnFocus = SourceHerc.bOpenGamepadInputOnFocus;
            BoxHerc.SteamGamepadTextInputMode = SourceHerc.SteamGamepadTextInputMode;
        }
        return Box;
    }

    private void OpenDialog()
    {
        AHercHUD HUD = Game::GetHUD();
        if (HUD == nullptr)
            return;

        Dialog = Cast<UCommonActivatableWidget>(HUD.PushWidgetToLayer(DialogClass, EUILayer::Menu));
        if (Dialog == nullptr)
            return;

        // Title and address row (the world-name row).
        SetLabel(Dialog, n"Text_Title", "Join Dedicated Server");
        SetLabel(Dialog, n"Text_Name", "Server Address");
        AddressBox = Cast<UEditableTextBox>(Find(Dialog, n"TextBox_WorldName"));

        // Port row: the Difficulty label becomes "Port"; a text box of the same class/style replaces
        // the Server Settings button in the slot right below it.
        SetLabel(Dialog, n"Text_Location_1", "Port");
        UWidget DifficultyCombo = Find(Dialog, n"ComboBox_DifficultySelector");
        if (DifficultyCombo != nullptr)
            DifficultyCombo.SetVisibility(ESlateVisibility::Collapsed);

        // Port + Password rows go into the slot right below the "Port" label (the Server Settings button
        // slot): a vertical stack of [port box, "Password" label, password box], all cloned from the
        // dialog's own text box and label so they share the game's styling.
        PortSlot = Cast<USizeBox>(Find(Dialog, n"SizeBox_0"));
        UCommonTextBlock SourceLabel = Cast<UCommonTextBlock>(Find(Dialog, n"Text_Name"));
        if (AddressBox != nullptr && PortSlot != nullptr)
        {
            PortBox = CloneTextBox(AddressBox);
            PasswordBox = CloneTextBox(AddressBox);
            PasswordBox.SetIsPassword(true);

            UVerticalBox Stack = Cast<UVerticalBox>(NewObject(Dialog, UVerticalBox));
            UVerticalBoxSlot PortRow = Cast<UVerticalBoxSlot>(Stack.AddChild(PortBox));
            if (SourceLabel != nullptr)
            {
                UCommonTextBlock PasswordLabel = Cast<UCommonTextBlock>(NewObject(Dialog, SourceLabel.Class));
                PasswordLabel.SetStyle(SourceLabel.GetStyle());
                PasswordLabel.SetText(FText::FromString("Password (if required)"));
                UVerticalBoxSlot LabelRow = Cast<UVerticalBoxSlot>(Stack.AddChild(PasswordLabel));
                if (LabelRow != nullptr)
                    LabelRow.SetPadding(FMargin(0, 14, 0, 4));
            }
            Stack.AddChild(PasswordBox);

            PortSlot.ClearHeightOverride();
            PortSlot.SetContent(Stack);
            UVerticalBoxSlot RowSlot = Cast<UVerticalBoxSlot>(PortSlot.Slot);
            if (RowSlot != nullptr)
                RowSlot.SetHorizontalAlignment(EHorizontalAlignment::HAlign_Center);
            bSyncFieldWidth = true; // match the address box width once it has been laid out
        }

        // Join button (the Create button) and the "please wait" page.
        UCommonButtonBase CreateButton = Cast<UCommonButtonBase>(Find(Dialog, n"Button_CreateWorld"));
        if (CreateButton != nullptr)
        {
            CreateButton.OnButtonBaseClicked.Clear();
            CreateButton.OnButtonBaseClicked.AddUFunction(this, n"OnJoinClicked");
            JoinDialogButton = Cast<UFoundationButtonBase>(CreateButton);
            if (JoinDialogButton != nullptr)
                JoinDialogButton.SetText(FText::FromString("Join"));
        }
        DialogSwitcher = Cast<UCommonActivatableWidgetSwitcher>(Find(Dialog, n"Switcher_Content"));
        StatusText = Cast<UCommonTextBlock>(Find(Dialog, n"CommonTextBlock_141"));

        // The side panel normally warns about hosting; use it to explain dedicated servers instead.
        UUserWidget Info = Cast<UUserWidget>(Find(Dialog, n"WBP_DisclaimerWidget"));
        if (Info != nullptr)
        {
            SetLabel(Info, n"Text_Large", "Dedicated Servers");
            SetLabel(Info, n"Text_Small", "Join an always-online world hosted on a Witchspire dedicated server. Everyone in the world needs the same version of the Co-op Overhaul mod. Your character on the server is tied to your Steam account and is saved by the server.");
            UUserWidget Section = Cast<UUserWidget>(Info.GetWidgetFromName(n"Widget_SectionText"));
            if (Section != nullptr)
                SetLabel(Section, n"TextBlock", "INFO");
        }

        // Remembered values (default port = the dedicated server default).
        UWSJoinSettingsSave Settings = Cast<UWSJoinSettingsSave>(Gameplay::LoadGameFromSlot(SettingsSlot, 0));
        const FString LastAddress = Settings != nullptr ? Settings.Address : "";
        const int LastPort = (Settings != nullptr && Settings.Port > 0) ? Settings.Port : WSMenu::DefaultPort;
        if (AddressBox != nullptr)
        {
            AddressBox.SetText(FText::FromString(LastAddress));
            AddressBox.SetHintText(FText::FromString("e.g. 192.168.1.20"));
            AddressBox.ClearError();
        }
        if (PortBox != nullptr)
        {
            PortBox.SetText(FText::FromString(f"{LastPort}"));
            PortBox.SetHintText(FText::FromString(f"{WSMenu::DefaultPort}"));
        }
        if (PasswordBox != nullptr)
            PasswordBox.SetText(FText());

        if (System::ParseParam(System::GetCommandLine(), "WSDumpUI"))
            WSMenu::DumpUserWidget(Dialog, "Join dedicated server dialog");
    }

    UFUNCTION()
    private void OnJoinClicked(UCommonButtonBase Button)
    {
        if (AddressBox == nullptr || PortBox == nullptr)
            return;

        const FString Address = AddressBox.GetText().ToString().TrimStartAndEnd();
        const FString PortText = PortBox.GetText().ToString().TrimStartAndEnd();
        AddressBox.ClearError();
        PortBox.ClearError();

        if (Address.IsEmpty() || Address.Contains(" ") || Address.Contains("?") || Address.Contains("/"))
        {
            AddressBox.SetError(FText::FromString("Enter the server's IP address or host name."));
            return;
        }
        int Port = WSMenu::DefaultPort;
        if (!PortText.IsEmpty())
        {
            Port = PortText.IsNumeric() ? String::Conv_StringToInt(PortText) : 0;
            if (Port < 1 || Port > 65535)
            {
                PortBox.SetError(FText::FromString("The port must be a number between 1 and 65535."));
                return;
            }
        }

        UWSClientStateSubsystem::Get().ServerPassword = PasswordBox != nullptr ? PasswordBox.GetText().ToString() : "";

        UWSJoinSettingsSave Settings = Cast<UWSJoinSettingsSave>(Gameplay::CreateSaveGameObject(UWSJoinSettingsSave));
        Settings.Address = Address;
        Settings.Port = Port;
        Gameplay::SaveGameToSlot(Settings, SettingsSlot, 0);

        FString PlayerName = SteamUtil::GetPersonaName();
        if (PlayerName.IsEmpty())
            PlayerName = WSDS::Param("WSName", "Witch");
        PendingUrl = f"{Address}:{Port}?Name={WSMenu::SanitizePlayerName(PlayerName)}";

        if (StatusText != nullptr)
            StatusText.SetText(FText::FromString("Connecting..."));
        if (DialogSwitcher != nullptr)
            DialogSwitcher.SetActiveWidgetIndex(1);

        UOnlineIdentitySubsystem Identity = UOnlineIdentitySubsystem::Get();
        if (Identity != nullptr && Identity.GetLoginStatus(0) == EOnlineLoginStatus::LoggedIn)
        {
            WSDS::Info("Menu: signing out of Epic Online Services for the direct-IP connection");
            UOnlineIdentitySubsystemLogout Logout = UOnlineIdentitySubsystemLogout::Logout(Identity, 0);
            if (Logout != nullptr)
                Logout.Activate();
            UWSClientStateSubsystem::Get().bSignedOutForDedicated = true;
            bWaitingForLogout = true;
            LogoutWaited = 0;
            return;
        }
        Connect();
    }

    // Debug (-WSOpenJoinDialog): open the dialog automatically a few seconds after the menu appears.
    private float AutoOpenTimer = 0;
    private bool bAutoOpened = false;

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (bSyncFieldWidth && AddressBox != nullptr && PortSlot != nullptr)
        {
            const float Width = AddressBox.GetDesiredSize().X;
            if (Width > 20)
            {
                PortSlot.SetWidthOverride(Width);
                bSyncFieldWidth = false;
            }
        }

        if (!bAutoOpened && DialogClass.IsValid() && System::ParseParam(System::GetCommandLine(), "WSOpenJoinDialog"))
        {
            AutoOpenTimer += DeltaTime;
            if (AutoOpenTimer > 6.0)
            {
                bAutoOpened = true;
                OpenDialog();
            }
        }

        if (!bWaitingForLogout)
            return;
        LogoutWaited += DeltaTime;
        UOnlineIdentitySubsystem Identity = UOnlineIdentitySubsystem::Get();
        const bool bSignedOut = Identity == nullptr || Identity.GetLoginStatus(0) != EOnlineLoginStatus::LoggedIn;
        if (bSignedOut || LogoutWaited > 8.0)
        {
            bWaitingForLogout = false;
            const FString Outcome = bSignedOut ? "complete" : "timed out";
            WSDS::Info(f"Menu: EOS sign-out {Outcome} after {LogoutWaited}s");
            Connect();
        }
    }

    private void Connect()
    {
        UWSClientStateSubsystem::Get().bAutoConnectUsed = true;
        WSDS::Info(f"Client: connecting to {PendingUrl} (direct IP, from the main menu)");
        System::ExecuteConsoleCommand(f"open {PendingUrl}");
    }
};
