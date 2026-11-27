// WitchspireCoopOverhaul - quick stack to nearby chests.
//
// A "Quick Stack" button next to the inventory's "Sort Inventory" button moves every item in the player's bag (not the hotbar) into the
// chests within 15 m that already hold the same kind of item. The game has its own sort and, for an open chest,
// "store similar"; this does the same for every chest around without opening them. Setting: Coop.QuickStack.

namespace WSQuickStack
{
    const float Range = 1500.0;
    const FString IconPath = "/Game/Art/UI/Icons/Placeholder/Items/FlatIcons/lorc/swap-bag.swap-bag";

    bool Enabled() { return WSCoop::Flag("QuickStack", true); }

    bool ServerAllows()
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        return Manager != nullptr && Manager.bQuickStackEnabled;
    }

    // Client: the button was pressed.
    void Request()
    {
        APlayerController PC = Gameplay::GetPlayerController(0);
        if (PC == nullptr)
            return;
        if (!ServerAllows())
        {
            WSCoop::ShowLocalNotice("Quick Stack", "This server doesn't allow quick stacking.");
            return;
        }
        if (System::IsServer())
        {
            ServerQuickStack(PC);
            return;
        }
        UWSIdentityComponent Channel = WSIdentity::GetComponent(PC);
        if (Channel != nullptr)
            Channel.ServerWSQuickStack();
    }

    void ServerQuickStack(APlayerController PC)
    {
        if (!System::IsServer() || PC == nullptr || !Enabled())
            return;
        APlayerCharacter Player = Cast<APlayerCharacter>(PC.GetControlledPawn());
        if (Player == nullptr || !Player.IsAlive())
            return;
        UInventoryComponent Bag = Player.InventoryComp;
        if (Bag == nullptr)
            return;
        const int FirstSlot = Player.HotbarComp != nullptr ? Player.HotbarComp.GetSlotCount() : 0;
        const FVector Here = Player.GetActorLocation();

        TArray<AChestActor> Chests;
        GetAllActorsOfClass(Chests);
        int ChestsNear = 0;
        int ChestsUsed = 0;
        int Moved = 0;
        for (AChestActor Chest : Chests)
        {
            if (!IsValid(Chest) || Chest.IsPreviewBuilding() || Chest.GetActorLocation().Distance(Here) > Range)
                continue;
            UInventoryComponent Store = UInventoryComponent::Get(Chest);
            if (Store == nullptr)
                continue;
            ChestsNear++;
            TArray<FGameplayTag> Kinds = Store.GetAllItemTypes();
            if (Kinds.Num() == 0)
                continue;
            int MovedHere = 0;
            for (int Slot = FirstSlot; Slot < Bag.GetCapacity(); Slot++)
            {
                UItemStack Stack = Bag.GetItemStackAtSlot(Slot);
                if (Stack == nullptr || !Kinds.Contains(Stack.GetItemTag()))
                    continue;
                const int Before = Stack.GetStackSize();
                Store.TransferItemStack(Stack);
                UItemStack After = Bag.GetItemStackAtSlot(Slot);
                const int Left = After != nullptr ? After.GetStackSize() : 0;
                MovedHere += Math::Max(0, Before - Left);
            }
            if (MovedHere > 0)
            {
                ChestsUsed++;
                Moved += MovedHere;
                SaveGame::MarkActorDirty(Chest);
            }
        }
        WSCoop::Info(f"Quick stack: {WSCoop::PlayerName(Player)} moved {Moved} item(s) into {ChestsUsed} of {ChestsNear} chest(s) nearby");
        if (ChestsNear == 0)
            WSCoop::Notify(Player, "There are no chests within 15 m.", "Quick Stack");
        else if (Moved == 0)
            WSCoop::Notify(Player, "None of the chests nearby holds the kinds of items in your bag.", "Quick Stack");
        else
        {
            const FString ChestWord = ChestsUsed == 1 ? "chest" : "chests";
            WSCoop::Notify(Player, f"Moved {Moved} item(s) into {ChestsUsed} {ChestWord} nearby.", "Quick Stack");
        }
    }
}

// Client: puts a Quick Stack button next to the sort button of the player's inventory.
UCLASS()
class UWSQuickStackView : UScriptWorldSubsystem
{
    private UHercButtonBase Button;
    private UInventoryWidget Attached;
    private float Clock = 0;
    private bool bTestDone = false;

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (WSDS::IsHeadlessHost())
            return;
        Clock += DeltaTime;
        if (Clock < 0.3)
            return;
        Clock = 0;
        AHercHUD HUD = Game::GetHUD();
        UPlayerInventoryWidget Inventory = HUD != nullptr ? HUD.Widget_PlayerInventory : nullptr;
        if (Inventory == nullptr)
            return;
        if (Attached != Inventory || !IsValid(Button))
            Attach(Inventory);
        // Developer test: press the button once, 30 s after joining.
        if (!bTestDone && System::ParseParam(System::GetCommandLine(), "WSQuickStackTest") && System::GetGameTimeInSeconds() > 30.0 && Game::GetLocalPlayer() != nullptr)
        {
            bTestDone = true;
            WSCoop::Info("QUICKSTACKTEST pressing Quick Stack");
            WSQuickStack::Request();
        }
        if (IsValid(Button))
        {
            Button.SetVisibility(WSQuickStack::ServerAllows() ? ESlateVisibility::Visible : ESlateVisibility::Collapsed);
            if (Inventory.IsActivated())
                SetLabel();
        }
    }

    private void Attach(UInventoryWidget Inventory)
    {
        Attached = Inventory;
        UHercButtonBase Sort = Inventory.Button_SortInventory;
        if (Sort == nullptr || Sort.GetParent() == nullptr)
            return;
        // The sort button sits in single-child boxes (a scale box); go up to the panel that holds several things.
        UWidget Anchor = Sort;
        UPanelWidget Parent = Sort.GetParent();
        while (Parent != nullptr && Cast<UContentWidget>(Parent) != nullptr && Parent.GetParent() != nullptr)
        {
            Anchor = Parent;
            Parent = Parent.GetParent();
        }
        if (Parent == nullptr)
            return;
        APlayerController PC = Gameplay::GetPlayerController(0);
        Button = Cast<UHercButtonBase>(WidgetBlueprint::CreateWidget(Sort.Class, PC));
        if (Button == nullptr)
            return;

        // A scale box like the sort button's, so both are the same size.
        UWidget Added = Button;
        UScaleBox SortScale = Cast<UScaleBox>(Anchor);
        if (SortScale != nullptr)
        {
            UScaleBox Scale = NewObject(Parent, UScaleBox);
            Scale.SetStretch(SortScale.Stretch);
            Scale.SetStretchDirection(SortScale.StretchDirection);
            Scale.SetUserSpecifiedScale(SortScale.UserSpecifiedScale);
            Scale.SetContent(Button);
            Added = Scale;
        }
        UPanelSlot NewSlot = Parent.AddChild(Added);
        const float Shift = Anchor.GetDesiredSize().X + 10.0;
        UHorizontalBoxSlot AnchorH = Cast<UHorizontalBoxSlot>(Anchor.Slot);
        UHorizontalBoxSlot NewH = Cast<UHorizontalBoxSlot>(NewSlot);
        if (AnchorH != nullptr && NewH != nullptr)
        {
            NewH.SetPadding(FMargin(AnchorH.Padding.Left + 6, AnchorH.Padding.Top, AnchorH.Padding.Right, AnchorH.Padding.Bottom));
            NewH.SetHorizontalAlignment(AnchorH.HorizontalAlignment);
            NewH.SetVerticalAlignment(AnchorH.VerticalAlignment);
        }
        UOverlaySlot AnchorO = Cast<UOverlaySlot>(Anchor.Slot);
        UOverlaySlot NewO = Cast<UOverlaySlot>(NewSlot);
        if (AnchorO != nullptr && NewO != nullptr)
        {
            NewO.SetHorizontalAlignment(AnchorO.HorizontalAlignment);
            NewO.SetVerticalAlignment(AnchorO.VerticalAlignment);
            NewO.SetPadding(FMargin(AnchorO.Padding.Left, AnchorO.Padding.Top, AnchorO.Padding.Right + Shift, AnchorO.Padding.Bottom));
        }
        UCanvasPanelSlot AnchorC = Cast<UCanvasPanelSlot>(Anchor.Slot);
        UCanvasPanelSlot NewC = Cast<UCanvasPanelSlot>(NewSlot);
        if (AnchorC != nullptr && NewC != nullptr)
        {
            NewC.SetAnchors(AnchorC.GetAnchors());
            NewC.SetAlignment(AnchorC.GetAlignment());
            NewC.SetAutoSize(true);
            NewC.SetPosition(AnchorC.GetPosition() - FVector2D(Shift, 0));
            NewC.SetZOrder(AnchorC.GetZOrder());
        }
        SetLabel();
        Button.SetToolTipText(FText::FromString("Move items from your bag (not the hotbar) into chests within 15 m that already hold the same kind of item"));
        Button.OnButtonBaseClicked.AddUFunction(this, n"OnClicked");
        WSCoop::Info(f"Quick stack: button added next to the sort button (in {Parent.Class.GetName()} '{Parent.GetName()}', anchor {Anchor.Class.GetName()})");
        if (System::ParseParam(System::GetCommandLine(), "WSDumpUI"))
            WSMenu::DumpUserWidget(Inventory, "Player inventory");
    }

    // After construction (the button's Blueprint sets its own text when it is built).
    private void SetLabel()
    {
        const FText Text = FText::FromString("Quick Stack");
        UFoundationButtonBase Labelled = Cast<UFoundationButtonBase>(Button);
        if (Labelled != nullptr)
            Labelled.SetText(Text);
        TArray<UWidget> All;
        Button.GetAllWidgets(All);
        for (UWidget W : All)
        {
            UTextBlock T = Cast<UTextBlock>(W);
            if (T != nullptr)
                T.SetText(Text);
        }
    }

    UFUNCTION()
    private void OnClicked(UCommonButtonBase Clicked)
    {
        WSQuickStack::Request();
    }
};
