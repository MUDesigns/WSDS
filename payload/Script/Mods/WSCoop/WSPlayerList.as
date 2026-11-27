// WitchspireCoopOverhaul - player list (hold P).
//
// While P is held, a panel lists everyone online: name, level, health, ping, how far away and in which direction,
// and whether they are down or asleep. The server publishes the list every two seconds
// (AWSCoopManager.PlayerInfos: "name|level|hp|maxhp|state"); positions come from the replicated player states, so
// distances are right at any range. Client side display; no setting.

namespace WSPlayerList
{
    FString Direction(const FVector& From, const FVector& To)
    {
        const FVector Delta = To - From;
        if (Delta.Size2D() < 1000.0)
            return "";
        // The game's compass: north is -Y, east is +X (see UCompassIconWidget_CardinalDirection).
        float Yaw = Math::RadiansToDegrees(Math::Atan2(Delta.Y, Delta.X));
        if (Yaw < 0)
            Yaw += 360.0;
        const int Sector = int(Math::Fmod(Yaw + 22.5, 360.0) / 45.0);
        switch (Sector)
        {
            case 0: return "E";
            case 1: return "SE";
            case 2: return "S";
            case 3: return "SW";
            case 4: return "W";
            case 5: return "NW";
            case 6: return "N";
            case 7: return "NE";
        }
        return "";
    }
}

// Server: publishes the list. Client: shows it while P is held.
UCLASS()
class UWSPlayerListSubsystem : UScriptWorldSubsystem
{
    private float Clock = 0;
    private UBorder Panel;
    private UVerticalBox Rows;
    private bool bShown = false;
    private TSubclassOf<UCommonTextStyle> TitleStyle;
    private TSubclassOf<UCommonTextStyle> RowStyle;

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (System::IsServer())
            Publish(DeltaTime);
        if (!WSDS::IsHeadlessHost())
            ClientTick();
    }

    // ---- server ----

    private void Publish(float DeltaTime)
    {
        Clock += DeltaTime;
        if (Clock < 2.0)
            return;
        Clock = 0;
        AWSCoopManager Manager = WSCoop::GetManager();
        AGameStateBase GameState = Gameplay::GetGameState();
        if (Manager == nullptr || GameState == nullptr)
            return;
        UWSSleepSubsystem Sleep = UWSSleepSubsystem::Get();
        TArray<FString> Infos;
        for (APlayerState PS : GameState.PlayerArray)
        {
            if (PS == nullptr || PS.IsSpectator() || PS.GetPlayerName().IsEmpty())
                continue;
            APlayerController PC = PS.GetPlayerController();
            if (PC != nullptr && PC.IsLocalController() && WSDS::IsHeadlessHost())
                continue;
            APlayerCharacter P = Cast<APlayerCharacter>(PS.GetPawn());
            FString Entry = PS.GetPlayerName().Replace("|", "/");
            if (P != nullptr)
            {
                const int Level = int(P.AbilityComp.GetLevel());
                const int Hp = int(P.AbilityComp.GetAttributeCurrentValue(UHealthAttributeSet::GetHealthAttribute()));
                const int MaxHp = int(P.AbilityComp.GetAttributeCurrentValue(UHealthAttributeSet::GetMaxHealthAttribute()));
                FString State = "ok";
                if (!P.IsAlive())
                    State = "down";
                else if (Sleep != nullptr && Sleep.IsSleeping(P))
                    State = "asleep";
                Entry += f"|{Level}|{Hp}|{MaxHp}|{State}";
            }
            else
                Entry += "|0|0|0|loading";
            Infos.Add(Entry);
        }
        if (Infos != Manager.PlayerInfos)
            Manager.PlayerInfos = Infos;
    }

    // ---- client ----

    private void ClientTick()
    {
        APlayerController PC = Gameplay::GetPlayerController(0);
        if (PC == nullptr || PC.GetControlledPawn() == nullptr || WSCoop::GetManager() == nullptr)
        {
            Hide();
            return;
        }
        const bool bHeld = PC.IsInputKeyDown(EKeys::P) || System::ParseParam(System::GetCommandLine(), "WSShowPlayerList");
        if (!bHeld)
        {
            Hide();
            return;
        }
        if (Panel == nullptr || !IsValid(Panel))
            Build(PC);
        if (Panel == nullptr)
            return;
        if (!bShown)
        {
            Panel.SetVisibility(ESlateVisibility::HitTestInvisible);
            bShown = true;
        }
        Fill(PC);
    }

    private void Hide()
    {
        if (bShown && Panel != nullptr && IsValid(Panel))
            Panel.SetVisibility(ESlateVisibility::Collapsed);
        bShown = false;
    }

    private void Build(APlayerController PC)
    {
        UHUDWidget HUD = Game::GetHUDWidget();
        if (HUD == nullptr)
            return;
        UPanelWidget Root = Cast<UPanelWidget>(HUD.GetRootWidget());
        if (Root == nullptr)
            return;
        TitleStyle = Cast<UClass>(LoadObject(UClass, WSMapMarkers::MapLabelStylePath));
        RowStyle = Cast<UClass>(LoadObject(UClass, WSMapMarkers::CompassLabelStylePath));
        Panel = NewObject(HUD, UBorder);
        Panel.SetBrushColor(FLinearColor(0.03, 0.02, 0.07, 0.82));
        Panel.SetPadding(FMargin(22, 14, 22, 16));
        Rows = NewObject(HUD, UVerticalBox);
        Panel.SetContent(Rows);
        UPanelSlot PanelSlot = Root.AddChild(Panel);
        UCanvasPanelSlot AsCanvas = Cast<UCanvasPanelSlot>(PanelSlot);
        UOverlaySlot AsOverlay = Cast<UOverlaySlot>(PanelSlot);
        if (AsCanvas != nullptr)
        {
            FAnchors Anchors;
            Anchors.Minimum = FVector2D(0.5, 0.18);
            Anchors.Maximum = FVector2D(0.5, 0.18);
            AsCanvas.SetAnchors(Anchors);
            AsCanvas.SetAlignment(FVector2D(0.5, 0.0));
            AsCanvas.SetAutoSize(true);
            AsCanvas.SetZOrder(100);
        }
        else if (AsOverlay != nullptr)
        {
            AsOverlay.SetHorizontalAlignment(EHorizontalAlignment::HAlign_Center);
            AsOverlay.SetVerticalAlignment(EVerticalAlignment::VAlign_Top);
            AsOverlay.SetPadding(FMargin(0, 160, 0, 0));
        }
        Panel.SetVisibility(ESlateVisibility::Collapsed);
        WSCoop::Info(f"Player list: panel added to the HUD ({Root.Class.GetName()})");
    }

    private UTextBlock Text(const FString& Value, bool bTitle, FLinearColor Color)
    {
        UTextBlock T = NewObject(Rows, UTextBlock);
        TSubclassOf<UCommonTextStyle> Style = bTitle ? TitleStyle : RowStyle;
        if (Style != nullptr)
            T.ApplyStyle(Style);
        T.SetText(FText::FromString(Value));
        T.SetColorAndOpacity(FSlateColor(Color));
        T.SetShadowOffset(FVector2D(1, 1));
        T.SetShadowColorAndOpacity(FLinearColor(0, 0, 0, 0.8));
        return T;
    }

    private void AddRow(const TArray<FString>& Cells, bool bHeader, FLinearColor Color)
    {
        UHorizontalBox Row = NewObject(Rows, UHorizontalBox);
        const float Widths0 = 190;
        TArray<float> Widths;
        Widths.Add(Widths0);
        Widths.Add(60);
        Widths.Add(110);
        Widths.Add(70);
        Widths.Add(110);
        Widths.Add(80);
        for (int i = 0; i < Cells.Num(); i++)
        {
            USizeBox Box = NewObject(Rows, USizeBox);
            Box.SetWidthOverride(Widths[Math::Min(i, Widths.Num() - 1)]);
            Box.SetContent(Text(Cells[i], bHeader, Color));
            Row.AddChildToHorizontalBox(Box);
        }
        UVerticalBoxSlot RowSlot = Rows.AddChildToVerticalBox(Row);
        RowSlot.SetPadding(FMargin(0, bHeader ? 0 : 3, 0, bHeader ? 6 : 0));
    }

    private void Fill(APlayerController PC)
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        Rows.ClearChildren();
        const int Count = Manager.PlayerInfos.Num();
        const FString PlayersWord = Count == 1 ? "player" : "players";
        UTextBlock Title = Text(f"{Count} {PlayersWord} online", true, FLinearColor(1.0, 0.85, 0.45, 1));
        UVerticalBoxSlot TitleSlot = Rows.AddChildToVerticalBox(Title);
        TitleSlot.SetPadding(FMargin(0, 0, 0, 8));

        TArray<FString> Header;
        Header.Add("Name");
        Header.Add("Level");
        Header.Add("Health");
        Header.Add("Ping");
        Header.Add("Where");
        Header.Add("");
        AddRow(Header, false, FLinearColor(0.7, 0.65, 0.85, 1));

        APawn Me = PC.GetControlledPawn();
        const FString MyName = PC.PlayerState != nullptr ? PC.PlayerState.GetPlayerName() : "";
        AGameStateBase GameState = Gameplay::GetGameState();
        for (const FString& Entry : Manager.PlayerInfos)
        {
            TArray<FString> F;
            Entry.ParseIntoArray(F, "|", false);
            if (F.Num() < 5)
                continue;
            APlayerState PS = nullptr;
            if (GameState != nullptr)
            {
                for (APlayerState S : GameState.PlayerArray)
                {
                    if (S != nullptr && S.GetPlayerName() == F[0])
                        PS = S;
                }
            }
            const bool bMe = F[0] == MyName;
            FString Where = bMe ? "you" : "";
            if (!bMe && PS != nullptr && Me != nullptr)
            {
                UWSMapMarkerView View = WSMapMarkers::View();
                const FVector Their = View != nullptr ? View.MateLocation(PS) : FVector::ZeroVector;
                if (!Their.IsNearlyZero())
                {
                    const int Meters = int(Me.GetActorLocation().Dist2D(Their) / 100.0);
                    Where = f"{Meters} m {WSPlayerList::Direction(Me.GetActorLocation(), Their)}";
                }
            }
            FString State = "";
            FLinearColor Color = bMe ? FLinearColor(0.85, 1.0, 0.85, 1) : FLinearColor(1, 1, 1, 1);
            if (F[4] == "down")
            {
                State = "Down!";
                Color = FLinearColor(1.0, 0.35, 0.35, 1);
            }
            else if (F[4] == "asleep")
            {
                State = "Asleep";
                Color = FLinearColor(0.6, 0.75, 1.0, 1);
            }
            else if (F[4] == "loading")
                State = "Joining";
            TArray<FString> Cells;
            Cells.Add(F[0]);
            Cells.Add(F[4] == "loading" ? "-" : F[1]);
            Cells.Add(F[4] == "loading" ? "-" : f"{F[2]} / {F[3]}");
            Cells.Add(PS != nullptr ? f"{int(PS.GetPingInMilliseconds())} ms" : "-");
            Cells.Add(Where);
            Cells.Add(State);
            AddRow(Cells, false, Color);
        }
    }
};
