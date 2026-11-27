// WitchspireCoopOverhaul - gatherable tracker (client side).
//
// A "Track Gatherables" button at the bottom right of the world map opens a list of the kinds of gatherables
// seen around you (trees, rocks, ores, flowers, satchels...), named after what they give. Pick the ones you
// want: the nearest few of each tracked kind are shown on the compass with the item's icon, name and distance.
// Only gatherables this game has loaded can be found (the world streams in a few hundred metres around you), and
// ones you have already gathered (still regrowing for you) are skipped. The choice is saved on this PC.

UCLASS()
class UWSGatherTrackerSave : USaveGame
{
    UPROPERTY()
    TArray<FString> Tracked;

    // "key|name|item tag|gives" of every kind seen so far, so the list also shows kinds that aren't loaded right now.
    UPROPERTY()
    TArray<FString> Known;
};

struct FWSGatherKind
{
    FString Key;
    FString Name;
    FGameplayTag ItemTag;
    FString Gives;
    int Nearby = 0;
    float Nearest = -1;
}

struct FWSGatherIcon
{
    AActor Node;
    FString Key;
    UCompassIconWidget Icon;
    bool bSeen = false;
}

// One row of the dialog (button click target).
UCLASS()
class UWSGatherRow : UObject
{
    FString Key;

    UFUNCTION()
    void Clicked()
    {
        UWSGatherTracker Tracker = UWSGatherTracker::Get();
        if (Tracker != nullptr)
            Tracker.Toggle(Key);
    }
};

namespace WSGatherTracker
{
    const FString SaveSlot = "WSGatherTracker";
    const int PerKind = 3;
    const FLinearColor TrackColor = FLinearColor(0.45, 1.0, 0.55, 1);

    bool IsUpper(int C) { return C >= 65 && C <= 90; }
    bool IsLower(int C) { return C >= 97 && C <= 122; }
    bool IsDigit(int C) { return C >= 48 && C <= 57; }

    // Words of a class name: "BP_TreeStump_Pine_C" -> [BP, Tree, Stump, Pine]
    TArray<FString> Words(const FString& ClassName)
    {
        TArray<FString> Out;
        FString N = ClassName;
        if (N.EndsWith("_C"))
            N = N.LeftChop(2);
        FString Word;
        for (int i = 0; i < N.Len(); i++)
        {
            const int C = int(N[i]) & 0xFFFF;
            const bool bBreak = C == 95 || IsDigit(C) || (IsUpper(C) && !Word.IsEmpty() && i > 0 && IsLower(int(N[i - 1]) & 0xFFFF));
            if (bBreak && !Word.IsEmpty())
            {
                Out.Add(Word);
                Word = "";
            }
            if (C != 95 && !IsDigit(C))
                Word += N.Mid(i, 1);
        }
        if (!Word.IsEmpty())
            Out.Add(Word);
        return Out;
    }

    bool IsNoiseWord(const FString& Word)
    {
        const FString L = Word.ToLower();
        return Word.Len() == 1 || L == "bp" || L == "harvestable" || L == "small" || L == "large" || L == "medium" || L == "big" || L == "huge" || L == "tiny" || L == "var" || L == "variant";
    }

    // A readable name for a gatherable class, with size variants merged:
    // "BP_Tree_Oak_Small_a_C" -> "Oak Tree", "BP_TreeStump_Pine_C" -> "Pine Stump",
    // "BP_MineralDeposit_Copper_C" -> "Copper Deposit", "BP_Harvestable_WitchSatchel1_C" -> "Witch Satchel".
    FString PrettyClassName(const FString& ClassName)
    {
        TArray<FString> W;
        for (FString Word : Words(ClassName))
        {
            if (!IsNoiseWord(Word))
                W.Add(Word);
        }
        if (W.Num() == 0)
            return ClassName;
        // The category comes first in class names and last in English.
        FString Category;
        if (W.Num() >= 3 && W[0] == "Tree" && W[1] == "Stump")
        {
            Category = "Stump";
            W.RemoveAt(0);
            W.RemoveAt(0);
        }
        else if (W.Num() >= 3 && W[0] == "Mineral" && W[1] == "Deposit")
        {
            Category = "Deposit";
            W.RemoveAt(0);
            W.RemoveAt(0);
        }
        else if (W.Num() >= 2 && (W[0] == "Tree" || W[0] == "Bush" || W[0] == "Rock" || W[0] == "Ore" || W[0] == "Flower" || W[0] == "Crystal"))
        {
            Category = W[0];
            W.RemoveAt(0);
        }
        FString Out;
        for (const FString& Word : W)
        {
            if (!Out.IsEmpty())
                Out += " ";
            Out += Word;
        }
        if (Out == "Treelog")
            Out = "Fallen Log";
        if (!Category.IsEmpty())
            Out += " " + Category;
        return Out;
    }
}

UCLASS()
class UWSGatherTracker : UScriptWorldSubsystem
{
    private TArray<FString> Tracked;
    private TMap<FString, FWSGatherKind> Kinds;
    private TMap<UClass, FString> ClassKinds;
    private TArray<FWSGatherIcon> Icons;
    private bool bLoaded = false;
    private float ScanClock = 0;
    private float LabelClock = 0;

    // Map UI.
    private TMap<UObject, UWidget> MapButtons;
    private UBorder Dialog;
    private UVerticalBox DialogRows;
    private TArray<UWSGatherRow> RowTargets;
    private TMap<FString, UTextBlock> RowStates;
    private bool bDialogDirty = false;
    private bool bDumped = false;

    bool IsDialogOpen() const
    {
        return Dialog != nullptr && IsValid(Dialog) && Dialog.IsVisible();
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (WSDS::IsHeadlessHost() || System::IsDedicatedServer())
            return;
        APawn Me = Game::GetLocalPlayer();
        if (Me == nullptr)
            return;
        if (!bLoaded)
            Load();
        if (bDialogDirty)
        {
            bDialogDirty = false;
            FillDialog();
        }
        // Developer test: -WSGatherClickRow=<part of a name> clicks that row once the dialog is open.
        const FString TestClick = WSDS::Param("WSGatherClickRow", "");
        if (!TestClick.IsEmpty() && !bTestClicked && IsDialogOpen())
        {
            for (UWSGatherRow Row : RowTargets)
            {
                FWSGatherKind Kind;
                if (Row != nullptr && Kinds.Find(Row.Key, Kind) && Kind.Name.Contains(TestClick))
                {
                    bTestClicked = true;
                    WSCoop::Info(f"GATHERTEST clicking row '{Kind.Name}'");
                    Row.Clicked();
                    break;
                }
            }
        }
        ScanClock += DeltaTime;
        LabelClock += DeltaTime;
        if (ScanClock >= 1.0)
        {
            ScanClock = 0;
            Scan(Me);
        }
        if (LabelClock >= 0.25)
        {
            LabelClock = 0;
            RefreshLabels();
        }
    }

    // ---- what is around ----

    // The item a gatherable gives for sure (its first fixed drop, else the first entry of its loot table).
    FGameplayTag GivesOf(ULootComponent Loot)
    {
        if (Loot == nullptr)
            return FGameplayTag();
        for (const FItemTableEntry& Entry : Loot.ItemTable)
        {
            if (Entry.ItemTag.IsValid() && UItemSubsystem::GetItemDefinition(Entry.ItemTag) != nullptr)
                return Entry.ItemTag;
        }
        for (const FLoot_ItemTableDefinitionEntry& Def : Loot.ItemTableDefinitions)
        {
            // A table of many possible drops (a satchel) has no single thing it gives.
            if (Def.ItemTableDefinition == nullptr || Def.ItemTableDefinition.Items.Num() > 3)
                continue;
            for (const FItemTableEntry& Entry : Def.ItemTableDefinition.Items)
            {
                if (Entry.ItemTag.IsValid() && UItemSubsystem::GetItemDefinition(Entry.ItemTag) != nullptr)
                    return Entry.ItemTag;
            }
        }
        return FGameplayTag();
    }

    // The kind of a gatherable. Things you pick up are named after the item ("Cotton Flower", "Stone"); trees,
    // stumps and deposits after themselves ("Birch Tree", "Copper Deposit"), with what they give.
    FString KindOf(AActor Node, ULootComponent Loot)
    {
        FString Key;
        if (ClassKinds.Find(Node.Class, Key))
            return Key;
        FWSGatherKind Kind;
        Kind.ItemTag = GivesOf(Loot);
        const UItemDefinition Item = Kind.ItemTag.IsValid() ? UItemSubsystem::GetItemDefinition(Kind.ItemTag) : nullptr;
        const bool bFixedPickup = Node.IsA(AHarvestableActor) && Loot != nullptr && Loot.ItemTable.Num() > 0 && Item != nullptr;
        if (bFixedPickup)
        {
            Kind.Name = Item.DisplayName.ToString();
            Kind.Key = f"pick:{Kind.ItemTag.ToString()}";
        }
        else
        {
            Kind.Name = WSGatherTracker::PrettyClassName(Node.Class.GetName().ToString());
            Kind.Key = f"kind:{Kind.Name}";
            if (Item != nullptr)
                Kind.Gives = Item.DisplayName.ToString();
        }
        ClassKinds.Add(Node.Class, Kind.Key);
        FWSGatherKind Old;
        if (!Kinds.Find(Kind.Key, Old) || Old.Name != Kind.Name || Old.Gives != Kind.Gives)
        {
            Kinds.Add(Kind.Key, Kind);
            Save();
        }
        return Kind.Key;
    }

    // Can be gathered right now (not gathered and regrowing, for this player).
    bool IsAvailable(AActor Node) const
    {
        AHarvestableActor Pickup = Cast<AHarvestableActor>(Node);
        if (Pickup != nullptr)
            return Pickup.Root.IsVisible() && !Pickup.IsHidden();
        AResourceNode Resource = Cast<AResourceNode>(Node);
        if (Resource != nullptr)
            return Resource.StaticMeshComponent.IsVisible() && !Resource.IsHidden();
        return false;
    }

    private void Scan(APawn Me)
    {
        const FVector Here = Me.GetActorLocation();
        TMap<FString, int> Counts;
        TMap<FString, float> Nearest;
        // Nearest available node(s) of each tracked kind.
        TArray<AActor> Best;
        TArray<float> BestDistance;
        TArray<FString> BestKey;

        TArray<AActor> Nodes;
        TArray<AHarvestableActor> Pickups;
        GetAllActorsOfClass(Pickups);
        for (AHarvestableActor A : Pickups)
            Nodes.Add(A);
        TArray<AResourceNode> Resources;
        GetAllActorsOfClass(Resources);
        for (AResourceNode R : Resources)
            Nodes.Add(R);

        FString Dump;
        for (AActor Node : Nodes)
        {
            if (!IsValid(Node))
                continue;
            ULootComponent Loot = Cast<ULootComponent>(Node.GetComponentByClass(ULootComponent));
            const FString Key = KindOf(Node, Loot);
            if (!IsAvailable(Node))
                continue;
            const float D = Node.GetActorLocation().Distance(Here);
            Counts.FindOrAdd(Key, 0) += 1;
            float Old = -1;
            if (!Nearest.Find(Key, Old) || D < Old)
                Nearest.Add(Key, D);
            if (Tracked.Contains(Key))
            {
                Best.Add(Node);
                BestDistance.Add(D);
                BestKey.Add(Key);
            }
        }
        for (auto& Pair : Kinds)
        {
            int Count = 0;
            Counts.Find(Pair.Key, Count);
            Pair.Value.Nearby = Count;
            float N = -1;
            Nearest.Find(Pair.Key, N);
            Pair.Value.Nearest = N;
        }

        if (!bDumped && System::ParseParam(System::GetCommandLine(), "WSGatherDump"))
        {
            bDumped = true;
            for (auto Pair : ClassKinds)
                WSCoop::Info(f"GATHERDUMP {Pair.Key.GetName()} -> {Pair.Value} '{Kinds[Pair.Value].Name}' gives '{Kinds[Pair.Value].Gives}' nearby={Kinds[Pair.Value].Nearby}");
        }

        // Keep the nearest PerKind of each tracked kind.
        TArray<AActor> Show;
        TArray<FString> ShowKey;
        for (const FString& Key : Tracked)
        {
            for (int Pick = 0; Pick < WSGatherTracker::PerKind; Pick++)
            {
                int BestIndex = -1;
                for (int i = 0; i < Best.Num(); i++)
                {
                    if (BestKey[i] != Key || Show.Contains(Best[i]))
                        continue;
                    if (BestIndex < 0 || BestDistance[i] < BestDistance[BestIndex])
                        BestIndex = i;
                }
                if (BestIndex < 0)
                    break;
                Show.Add(Best[BestIndex]);
                ShowKey.Add(Key);
            }
        }
        SyncIcons(Show, ShowKey);
        if (IsDialogOpen())
            UpdateRowStates();

        // Developer test: -WSGatherTrack=<part of a name> tracks the first matching kind once it is seen.
        const FString TestTrack = WSDS::Param("WSGatherTrack", "");
        if (!TestTrack.IsEmpty() && !bTestTracked)
        {
            for (auto Pair : Kinds)
            {
                if (Pair.Value.Name.Contains(TestTrack) && Pair.Value.Nearby > 0)
                {
                    bTestTracked = true;
                    SetTracked(Pair.Key, true);
                    WSCoop::Info(f"GATHERTEST tracking {Pair.Key} '{Pair.Value.Name}' ({Pair.Value.Nearby} nearby)");
                    break;
                }
            }
        }
        if (bTestTracked && System::ParseParam(System::GetCommandLine(), "WSGatherDump"))
            WSCoop::Info(f"GATHERTEST compass icons={Icons.Num()}");
    }

    private bool bTestTracked = false;
    private bool bTestClicked = false;

    // ---- compass ----

    private void SyncIcons(const TArray<AActor>& Show, const TArray<FString>& ShowKey)
    {
        UWSMapMarkerView View = WSMapMarkers::View();
        APlayerController PC = Gameplay::GetPlayerController(0);
        UHUDWidget HUD = Game::GetHUDWidget();
        if (View == nullptr || PC == nullptr || HUD == nullptr || HUD.Widget_Compass == nullptr || View.MarkerIconClass == nullptr)
            return;
        for (FWSGatherIcon& I : Icons)
            I.bSeen = false;
        for (int s = 0; s < Show.Num(); s++)
        {
            int Index = -1;
            for (int i = 0; i < Icons.Num(); i++)
            {
                if (Icons[i].Node == Show[s])
                {
                    Index = i;
                    break;
                }
            }
            if (Index < 0)
            {
                FWSGatherIcon NewIcon;
                NewIcon.Node = Show[s];
                NewIcon.Key = ShowKey[s];
                NewIcon.Icon = View.MakeCompassIcon(View.MarkerIconClass, Show[s].GetActorLocation(), PC, HUD);
                Icons.Add(NewIcon);
                Index = Icons.Num() - 1;
            }
            Icons[Index].bSeen = true;
            if (Icons[Index].Icon != nullptr)
            {
                Icons[Index].Icon.WSSetTargetLocation(Show[s].GetActorLocation() + FVector(0, 0, 100));
                View.ColorCompassIcon(Icons[Index].Icon, WSGatherTracker::TrackColor, IconTexture(ShowKey[s]));
            }
        }
        for (int i = Icons.Num() - 1; i >= 0; i--)
        {
            if (!Icons[i].bSeen)
            {
                View.RemoveCompassIcon(Icons[i].Icon, HUD);
                Icons.RemoveAt(i);
            }
        }
        RefreshLabels();
    }

    private void RefreshLabels()
    {
        UWSMapMarkerView View = WSMapMarkers::View();
        APlayerController PC = Gameplay::GetPlayerController(0);
        if (View == nullptr || PC == nullptr)
            return;
        for (FWSGatherIcon& I : Icons)
        {
            FWSGatherKind Kind;
            if (I.Icon != nullptr && Kinds.Find(I.Key, Kind))
                View.SetCompassLabel(I.Icon, Kind.Name, PC);
        }
    }

    // The item's icon once the game has loaded it (inventory, this dialog...), else a generic one.
    UTexture2D IconTexture(const FString& Key)
    {
        FWSGatherKind Kind;
        if (Kinds.Find(Key, Kind) && Kind.ItemTag.IsValid())
        {
            const UItemDefinition Item = UItemSubsystem::GetItemDefinition(Kind.ItemTag);
            if (Item != nullptr)
            {
                UTexture2D Texture = Cast<UTexture2D>(Item.Icon.Image.Get());
                if (Texture != nullptr)
                    return Texture;
            }
        }
        UWSMapMarkerView View = WSMapMarkers::View();
        return View != nullptr ? View.IconFor("loot") : nullptr;
    }

    // ---- tracking ----

    void Toggle(const FString& Key)
    {
        if (Tracked.Contains(Key))
            Tracked.Remove(Key);
        else
            Tracked.Add(Key);
        WSCoop::Info(f"Gather tracker: {Tracked.Num()} kind(s) tracked");
        Save();
        ScanClock = 1.0; // update the compass right away
        bDialogDirty = true;
    }

    void SetTracked(const FString& Key, bool bOn)
    {
        if (bOn != Tracked.Contains(Key))
            Toggle(Key);
    }

    private void Load()
    {
        bLoaded = true;
        UWSGatherTrackerSave SaveData = Cast<UWSGatherTrackerSave>(Gameplay::LoadGameFromSlot(WSGatherTracker::SaveSlot, 0));
        if (SaveData == nullptr)
            return;
        Tracked = SaveData.Tracked;
        for (const FString& Entry : SaveData.Known)
        {
            TArray<FString> F;
            Entry.ParseIntoArray(F, "|", false);
            if (F.Num() < 3 || Kinds.Contains(F[0]))
                continue;
            FWSGatherKind Kind;
            Kind.Key = F[0];
            Kind.Name = F[1];
            Kind.ItemTag = FGameplayTag::RequestGameplayTag(FName(F[2]), false);
            if (F.Num() >= 4)
                Kind.Gives = F[3];
            Kinds.Add(Kind.Key, Kind);
        }
    }

    private void Save()
    {
        UWSGatherTrackerSave SaveData = Cast<UWSGatherTrackerSave>(Gameplay::CreateSaveGameObject(UWSGatherTrackerSave));
        SaveData.Tracked = Tracked;
        for (auto Pair : Kinds)
        {
            const FString Tag = Pair.Value.ItemTag.IsValid() ? Pair.Value.ItemTag.ToString() : "";
            const FString CleanName = Pair.Value.Name.Replace("|", "/");
            const FString CleanGives = Pair.Value.Gives.Replace("|", "/");
            SaveData.Known.Add(f"{Pair.Key}|{CleanName}|{Tag}|{CleanGives}");
        }
        Gameplay::SaveGameToSlot(SaveData, WSGatherTracker::SaveSlot, 0);
    }

    // ---- map button and dialog ----

    void ShowMapButton(UWorldMapWidget Widget)
    {
        CloseDialog();
        UWidget Existing;
        if (MapButtons.Find(Widget, Existing) && IsValid(Existing))
        {
            if (System::ParseParam(System::GetCommandLine(), "WSGatherOpenDialog"))
                OpenDialog();
            return;
        }
        UPanelWidget Root = WSMapMarkers::MapCanvas(Widget);
        if (Root == nullptr)
            return;
        UWSMapMarkerView View = WSMapMarkers::View();
        UButton Button = NewObject(Widget, UButton);
        UHorizontalBox Content = NewObject(Widget, UHorizontalBox);
        UImage Image = NewObject(Widget, UImage);
        if (View != nullptr)
            Image.SetBrushFromTexture(View.IconFor("loot"));
        Image.SetDesiredSizeOverride(FVector2D(22, 22));
        Image.SetColorAndOpacity(WSGatherTracker::TrackColor);
        Content.AddChildToHorizontalBox(Image).SetVerticalAlignment(EVerticalAlignment::VAlign_Center);
        UTextBlock Text = MakeText(Widget, "Track Gatherables");
        UHorizontalBoxSlot TextSlot = Content.AddChildToHorizontalBox(Text);
        TextSlot.SetVerticalAlignment(EVerticalAlignment::VAlign_Center);
        TextSlot.SetPadding(FMargin(6, 0, 2, 0));
        Button.AddChild(Content);
        Button.SetBackgroundColor(FLinearColor(0.08, 0.06, 0.14, 0.85));
        Button.SetToolTipText(FText::FromString("Pick gatherables to show the nearest ones on your compass"));
        Button.OnClicked.AddUFunction(this, n"OpenDialogClicked");
        AddToCanvas(Root, Button, FVector2D(1, 1), FVector2D(1, 1), FVector2D(-24, -28));
        MapButtons.Add(Widget, Button);

        // The dialog lives on the same canvas, hidden until the button is pressed.
        Dialog = NewObject(Widget, UBorder);
        Dialog.SetBrushColor(FLinearColor(0.04, 0.03, 0.08, 0.94));
        Dialog.SetPadding(FMargin(22, 16, 22, 16));
        UVerticalBox Column = NewObject(Widget, UVerticalBox);
        Dialog.SetContent(Column);
        UTextBlock Title = MakeText(Widget, "Track Gatherables");
        Title.SetColorAndOpacity(FSlateColor(FLinearColor(1.0, 0.85, 0.45, 1)));
        Column.AddChildToVerticalBox(Title);
        UTextBlock Hint = MakeText(Widget, "Pick what you want to find. The nearest 3 of each show on your compass.\nOnly gatherables loaded around you are found; ones you already gathered are skipped.");
        Hint.SetColorAndOpacity(FSlateColor(FLinearColor(0.75, 0.72, 0.85, 1)));
        Column.AddChildToVerticalBox(Hint).SetPadding(FMargin(0, 4, 0, 10));
        USizeBox ListBox = NewObject(Widget, USizeBox);
        ListBox.SetWidthOverride(460);
        ListBox.SetMaxDesiredHeight(330);
        UScrollBox Scroll = NewObject(Widget, UScrollBox);
        DialogRows = NewObject(Widget, UVerticalBox);
        Scroll.AddChild(DialogRows);
        ListBox.SetContent(Scroll);
        Column.AddChildToVerticalBox(ListBox);
        UHorizontalBox Buttons = NewObject(Widget, UHorizontalBox);
        UButton Clear = MakeTextButton(Widget, "Track none");
        Clear.OnClicked.AddUFunction(this, n"ClearClicked");
        UButton Close = MakeTextButton(Widget, "Close");
        Close.OnClicked.AddUFunction(this, n"CloseClicked");
        Buttons.AddChildToHorizontalBox(Clear).SetPadding(FMargin(0, 0, 8, 0));
        Buttons.AddChildToHorizontalBox(Close);
        Column.AddChildToVerticalBox(Buttons).SetPadding(FMargin(0, 12, 0, 0));
        AddToCanvas(Root, Dialog, FVector2D(0.5, 0.5), FVector2D(0.5, 0.5), FVector2D(0, 0));
        Dialog.SetVisibility(ESlateVisibility::Collapsed);
        WSCoop::Info("Gather tracker: map button added");
        if (System::ParseParam(System::GetCommandLine(), "WSGatherOpenDialog"))
            OpenDialog();
    }

    private void AddToCanvas(UPanelWidget Root, UWidget Child, FVector2D Anchor, FVector2D Alignment, FVector2D Position)
    {
        UPanelSlot NewSlot = Root.AddChild(Child);
        UCanvasPanelSlot AsCanvas = Cast<UCanvasPanelSlot>(NewSlot);
        UOverlaySlot AsOverlay = Cast<UOverlaySlot>(NewSlot);
        if (AsCanvas != nullptr)
        {
            FAnchors Anchors;
            Anchors.Minimum = Anchor;
            Anchors.Maximum = Anchor;
            AsCanvas.SetAnchors(Anchors);
            AsCanvas.SetAlignment(Alignment);
            AsCanvas.SetAutoSize(true);
            AsCanvas.SetPosition(Position);
            AsCanvas.SetZOrder(60);
        }
        else if (AsOverlay != nullptr)
        {
            AsOverlay.SetHorizontalAlignment(Anchor.X > 0.9 ? EHorizontalAlignment::HAlign_Right : EHorizontalAlignment::HAlign_Center);
            AsOverlay.SetVerticalAlignment(Anchor.Y > 0.9 ? EVerticalAlignment::VAlign_Bottom : EVerticalAlignment::VAlign_Center);
            AsOverlay.SetPadding(FMargin(0, 0, -Position.X, -Position.Y));
        }
    }

    private UTextBlock MakeText(UObject Owner, const FString& Value)
    {
        UTextBlock T = NewObject(Owner, UTextBlock);
        UWSMapMarkerView View = WSMapMarkers::View();
        if (View != nullptr && View.MapLabelStyle != nullptr)
            T.ApplyStyle(View.MapLabelStyle);
        T.SetText(FText::FromString(Value));
        T.SetShadowOffset(FVector2D(1, 1));
        T.SetShadowColorAndOpacity(FLinearColor(0, 0, 0, 0.9));
        return T;
    }

    private UButton MakeTextButton(UObject Owner, const FString& Label)
    {
        UButton B = NewObject(Owner, UButton);
        B.AddChild(MakeText(Owner, Label));
        B.SetBackgroundColor(FLinearColor(0.12, 0.09, 0.2, 0.95));
        return B;
    }

    UFUNCTION()
    private void OpenDialogClicked()
    {
        if (Dialog == nullptr || !IsValid(Dialog))
            return;
        if (IsDialogOpen())
        {
            CloseDialog();
            return;
        }
        Dialog.SetVisibility(ESlateVisibility::Visible);
        FillDialog();
        bDialogDirty = false;
        WSCoop::Info(f"Gather tracker: dialog opened ({Kinds.Num()} kinds known)");
    }

    void OpenDialog()
    {
        OpenDialogClicked();
    }

    UFUNCTION()
    private void CloseClicked()
    {
        CloseDialog();
    }

    UFUNCTION()
    private void ClearClicked()
    {
        Tracked.Empty();
        Save();
        ScanClock = 1.0;
        bDialogDirty = true;
    }

    void CloseDialog()
    {
        if (Dialog != nullptr && IsValid(Dialog))
            Dialog.SetVisibility(ESlateVisibility::Collapsed);
    }

    // Rows: tracked first, then the kinds found nearby (nearest first), then the rest seen before (A-Z).
    private void FillDialog()
    {
        if (DialogRows == nullptr || !IsValid(DialogRows) || !IsDialogOpen())
            return;
        DialogRows.ClearChildren();
        RowTargets.Empty();
        RowStates.Empty();
        TArray<FWSGatherKind> Order;
        for (auto Pair : Kinds)
            Order.Add(Pair.Value);
        // Simple insertion sort: tracked, then nearby by distance, then by name.
        for (int i = 1; i < Order.Num(); i++)
        {
            FWSGatherKind Item = Order[i];
            int j = i - 1;
            while (j >= 0 && Before(Item, Order[j]))
            {
                Order[j + 1] = Order[j];
                j--;
            }
            Order[j + 1] = Item;
        }
        if (Order.Num() == 0)
        {
            DialogRows.AddChildToVerticalBox(MakeText(DialogRows, "Nothing gatherable is loaded around you yet."));
            return;
        }
        for (const FWSGatherKind& Kind : Order)
            AddRow(Kind);
    }

    private FString StateTextFor(const FWSGatherKind& Kind) const
    {
        const FString Count = Kind.Nearby > 0 ? f"{Kind.Nearby} nearby" : "none nearby";
        return Tracked.Contains(Kind.Key) ? f"Tracking - {Count}" : Count;
    }

    private void UpdateRowStates()
    {
        for (auto Pair : RowStates)
        {
            FWSGatherKind Kind;
            if (IsValid(Pair.Value) && Kinds.Find(Pair.Key, Kind))
                Pair.Value.SetText(FText::FromString(StateTextFor(Kind)));
        }
        // A kind seen for the first time joins the list.
        if (RowStates.Num() != Kinds.Num())
            bDialogDirty = true;
    }

    private bool Before(const FWSGatherKind& A, const FWSGatherKind& B) const
    {
        const bool TA = Tracked.Contains(A.Key);
        const bool TB = Tracked.Contains(B.Key);
        if (TA != TB)
            return TA;
        const bool NA = A.Nearby > 0;
        const bool NB = B.Nearby > 0;
        if (NA != NB)
            return NA;
        if (NA && NB && A.Nearest != B.Nearest)
            return A.Nearest < B.Nearest;
        return A.Name.Compare(B.Name) < 0;
    }

    private void AddRow(const FWSGatherKind& Kind)
    {
        const bool bOn = Tracked.Contains(Kind.Key);
        UButton Row = NewObject(DialogRows, UButton);
        Row.SetBackgroundColor(bOn ? FLinearColor(0.3, 0.55, 0.3, 1.0) : FLinearColor(0.1, 0.08, 0.16, 0.9));
        UHorizontalBox Line = NewObject(DialogRows, UHorizontalBox);
        UCommonLazyImage Icon = NewObject(DialogRows, UCommonLazyImage);
        if (Kind.ItemTag.IsValid())
        {
            const UItemDefinition Item = UItemSubsystem::GetItemDefinition(Kind.ItemTag);
            if (Item != nullptr)
                Icon.SetBrushFromLazyDisplayAsset(Item.Icon.Image);
        }
        else
        {
            UWSMapMarkerView View = WSMapMarkers::View();
            if (View != nullptr)
                Icon.SetBrushFromTexture(View.IconFor("loot"));
        }
        USizeBox IconBox = NewObject(DialogRows, USizeBox);
        IconBox.SetWidthOverride(30);
        IconBox.SetHeightOverride(30);
        IconBox.SetContent(Icon);
        Line.AddChildToHorizontalBox(IconBox).SetVerticalAlignment(EVerticalAlignment::VAlign_Center);
        const FString RowName = Kind.Gives.IsEmpty() ? Kind.Name : f"{Kind.Name}  ({Kind.Gives})";
        UTextBlock NameText = MakeText(DialogRows, RowName);
        UHorizontalBoxSlot NameSlot = Line.AddChildToHorizontalBox(NameText);
        NameSlot.SetPadding(FMargin(10, 0, 10, 0));
        NameSlot.SetVerticalAlignment(EVerticalAlignment::VAlign_Center);
        FSlateChildSize Fill;
        Fill.SizeRule = ESlateSizeRule::Fill;
        NameSlot.SetSize(Fill);
        const FString State = StateTextFor(Kind);
        UTextBlock StateText = MakeText(DialogRows, State);
        StateText.SetColorAndOpacity(FSlateColor(bOn ? FLinearColor(0.75, 1.0, 0.75, 1) : FLinearColor(0.7, 0.68, 0.8, 1)));
        Line.AddChildToHorizontalBox(StateText).SetVerticalAlignment(EVerticalAlignment::VAlign_Center);
        RowStates.Add(Kind.Key, StateText);
        UButtonSlot LineSlot = Cast<UButtonSlot>(Row.AddChild(Line));
        if (LineSlot != nullptr)
        {
            LineSlot.SetHorizontalAlignment(EHorizontalAlignment::HAlign_Fill);
            LineSlot.SetPadding(FMargin(8, 3, 8, 3));
        }
        UWSGatherRow Target = NewObject(this, UWSGatherRow);
        Target.Key = Kind.Key;
        RowTargets.Add(Target);
        Row.OnClicked.AddUFunction(Target, n"Clicked");
        DialogRows.AddChildToVerticalBox(Row).SetPadding(FMargin(0, 2, 0, 2));
    }

    // Tests.
    int NumIcons() const
    {
        return Icons.Num();
    }

    TArray<FString> KindKeys() const
    {
        TArray<FString> Out;
        for (auto Pair : Kinds)
            Out.Add(f"{Pair.Key}={Pair.Value.Name}({Pair.Value.Nearby})");
        return Out;
    }
};
