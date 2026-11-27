// WitchspireCoopOverhaul - workstation extras.
//
// Weapon re-roll (Coop.WeaponReroll): at the weapon enhancement station (item crafting station), a "Re-roll
// Stats" button next to Upgrade rolls new random stat lines of the same rarity for a Master or Grandmaster weapon
// for 5 Brilliant Spirit Dust (taken from the bag or the hearth's shared storage, like upgrade costs). The dust is
// spent as soon as the roll is made; the player then sees the new roll next to the current stats and picks which
// to keep (closing the choice keeps the current stats). Common weapons have no stat lines to re-roll.
//
// Familiar salvage (Coop.FamiliarSalvage): familiars can be put into the salvage station. Salvaging one gives
// 1 Magick Essence and 2 Spirit Dust per rarity step (Common 1, Rare 2, Epic 3, Legendary 4); the familiar's level
// picks the tier of both: level 9 and below Spirit Dust / Lesser Magick Essence, 10-19 Greater, 20 and above
// Brilliant. A familiar that is out in the world (summoned) has to be dismissed first.

namespace WSWeaponReroll
{
    const int DustCost = 5;
    const FName DustTag = n"Items.SpiritDustBrilliant";

    bool Enabled() { return WSCoop::Flag("WeaponReroll", true); }

    bool ServerAllows()
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        return Manager != nullptr && Manager.bWeaponRerollEnabled;
    }

    FGameplayTag Dust()
    {
        return FGameplayTag::RequestGameplayTag(DustTag, false);
    }

    // Master and Grandmaster spellblades, staffs and wands.
    bool IsMasterWeapon(const UItemStack Stack)
    {
        if (Stack == nullptr || Stack.ItemDefinition == nullptr)
            return false;
        const FString Tag = Stack.GetItemTag().ToString();
        return Tag.EndsWith("_Master") || Tag.EndsWith("_Grandmaster");
    }

    bool CanReroll(const UItemStack Stack)
    {
        if (!IsMasterWeapon(Stack))
            return false;
        const UItemRuntimeFragment_Rarity Rarity = Stack.GetRuntimeFragment_Rarity();
        return Rarity != nullptr && Rarity.bCanHaveRarityEffects;
    }

    int DustOwned(AItemCraftingWorkstation Station, UItemStack Stack)
    {
        UInventoryComponent Inventory = Stack.GetOwningInventory();
        USharedInventoryComponent Shared = Station.GetSharedInventoryComp();
        if (Shared != nullptr)
            return Shared.GetTotalItemCountByTagWithInventory(Inventory, Dust());
        return Inventory != nullptr ? Inventory.GetTotalItemCountByTag(Dust()) : 0;
    }

    FString StatLines(const UItemRuntimeFragment_Rarity Rarity)
    {
        return EffectLines(Rarity.RarityEffects);
    }

    FString EffectLines(const TArray<FPassiveEffect>& Effects)
    {
        FString Out;
        for (const FPassiveEffect& Effect : Effects)
        {
            if (!Out.IsEmpty())
                Out += "\n";
            Out += Effect.GetLocalizedText().ToString();
        }
        return Out;
    }

    // ---- client: button next to Upgrade ----

    void Attach(UItemCraftingWeaponCustomizationContentWidget Widget, UFoundationButtonBase UpgradeButton)
    {
        UWSWorkstationExtras Extras = UWSWorkstationExtras::Get();
        if (Extras != nullptr)
            Extras.AttachRerollButton(Widget, UpgradeButton);
    }

    void Refresh(UItemCraftingWeaponCustomizationContentWidget Widget, AItemCraftingWorkstation Station, UItemStack Weapon)
    {
        UWSWorkstationExtras Extras = UWSWorkstationExtras::Get();
        if (Extras != nullptr)
            Extras.RefreshRerollButton(Widget, Station, Weapon);
    }

    // ---- server ----

    void ServerReroll(APlayerController PC, AItemCraftingWorkstation Station)
    {
        if (!System::IsServer() || PC == nullptr || Station == nullptr || !Enabled())
            return;
        APlayerCharacter Player = Cast<APlayerCharacter>(PC.GetControlledPawn());
        if (Player == nullptr || Player.GetActorLocation().Distance(Station.GetActorLocation()) > 1500.0)
            return;
        UItemStack Weapon = Station.GetItemStackCraftingComponent().GetCurrentCraftingItemStack();
        if (!CanReroll(Weapon))
        {
            WSCoop::Notify(Player, "Only Master and Grandmaster weapons can have their stats re-rolled.", "Re-roll Stats");
            return;
        }
        UItemRuntimeFragment_Rarity Rarity = Weapon.GetRuntimeFragment_Rarity();
        if (Rarity.GetRarity() == EItemRarity::Common)
        {
            WSCoop::Notify(Player, "Common weapons have no stat lines to re-roll.", "Re-roll Stats");
            return;
        }
        const int Owned = DustOwned(Station, Weapon);
        if (Owned < DustCost && !CVar::Crafting::RecipeCostDisabled.Bool)
        {
            WSCoop::Notify(Player, f"You need {DustCost} Brilliant Spirit Dust (you have {Owned}).", "Re-roll Stats");
            return;
        }

        TArray<FSimpleRecipeCost> Costs;
        FSimpleRecipeCost Cost;
        Cost.Tag = Dust();
        Cost.Amount = DustCost;
        Costs.Add(Cost);
        UWSWorkstationExtras Extras = UWSWorkstationExtras::Get();
        if (Extras == nullptr)
            return;
        // The dust is spent now, whichever roll the player keeps.
        Station.ConsumeUpgradeCosts(Costs);

        FWSPendingReroll Offer;
        Offer.Weapon = Weapon;
        Offer.Station = Station;
        Offer.Rarity = Rarity.GetRarity();
        Game::GetGameInstance().ItemRaritySettings.RollPassiveEffects(Weapon, Offer.Rarity, Offer.Effects);
        Extras.SetPending(PC, Offer);

        const FString Current = StatLines(Rarity);
        const FString New = EffectLines(Offer.Effects);
        const FString CurrentLine = Current.Replace("\n", "; ");
        const FString NewLine = New.Replace("\n", "; ");
        WSCoop::Info(f"Weapon re-roll by {WSCoop::PlayerName(Player)}: {Weapon.GetItemTag()} current [{CurrentLine}], offered [{NewLine}]");
        if (PC.IsLocalController())
        {
            Extras.ShowOffer(Current, New);
            return;
        }
        UWSIdentityComponent Channel = WSIdentity::GetComponent(PC);
        if (Channel != nullptr)
            Channel.WSWeaponRerollOffer(Current, New);
    }

    // The player's answer to the offered roll. Anything other than taking it keeps the current stats.
    void ServerChoose(APlayerController PC, bool bTakeNew)
    {
        UWSWorkstationExtras Extras = UWSWorkstationExtras::Get();
        if (!System::IsServer() || PC == nullptr || Extras == nullptr)
            return;
        FWSPendingReroll Offer;
        APlayerCharacter Player = Cast<APlayerCharacter>(PC.GetControlledPawn());
        if (!Extras.TakePending(PC, Offer))
        {
            WSCoop::Info(f"Weapon re-roll by {WSCoop::PlayerName(Player)}: answer with no roll waiting (ignored)");
            return;
        }
        if (!bTakeNew)
        {
            WSCoop::Info(f"Weapon re-roll by {WSCoop::PlayerName(Player)}: kept the current stats");
            return;
        }
        if (!IsValid(Offer.Weapon) || Player == nullptr)
            return;
        UItemRuntimeFragment_Rarity Rarity = Offer.Weapon.GetRuntimeFragment_Rarity();
        if (Rarity == nullptr || Rarity.GetRarity() != Offer.Rarity)
        {
            WSCoop::Notify(Player, "The weapon changed since the roll, so it keeps its current stats.", "Re-roll Stats");
            return;
        }

        // A weapon in hand has its stat effects active: swap them for the new ones.
        bool bEquipped = false;
        for (UHercEquipmentInstance Equipment : Player.EquipmentComp.GetAllEquippedItems())
        {
            if (Equipment != nullptr && Equipment.ItemStack == Offer.Weapon)
                bEquipped = true;
        }
        if (bEquipped)
            Rarity.RemoveEffects(Player.AbilityComp);
        Rarity.SetRarity(Offer.Rarity, Offer.Effects);
        if (bEquipped)
            Rarity.ApplyEffects(Player.AbilityComp);

        if (IsValid(Offer.Station))
        {
            Offer.Station.GetItemStackCraftingComponent().MarkItemStackDirty();
            Offer.Station.GetItemStackCraftingComponent().BroadcastItemStackUpdatedEvent();
        }
        const FString NewStats = StatLines(Rarity);
        const FString NewLine = NewStats.Replace("\n", "; ");
        WSCoop::Info(f"Weapon re-roll by {WSCoop::PlayerName(Player)}: took the new stats [{NewLine}]");
        WSCoop::Notify(Player, f"New stats:\n{NewStats}", "Stats Re-rolled");
    }
}

namespace WSFamiliarSalvage
{
    bool Enabled() { return WSCoop::Flag("FamiliarSalvage", true); }

    // Familiars may go into the salvage station (checked by the station's input on the player's game).
    bool AllowedHere()
    {
        if (System::IsServer())
            return Enabled();
        AWSCoopManager Manager = WSCoop::GetManager();
        return Manager != nullptr && Manager.bFamiliarSalvageEnabled;
    }

    bool IsFamiliar(const UItemStack Stack)
    {
        return Stack != nullptr && Stack.GetRuntimeFragment(UItemRuntimeFragment_FamiliarInfo) != nullptr;
    }

    // A familiar that is out in the world (summoned) has to be dismissed first.
    bool CanSalvage(const UItemStack Stack)
    {
        if (!IsFamiliar(Stack) || !AllowedHere())
            return false;
        const UItemRuntimeFragment_FamiliarInfo Info = Cast<UItemRuntimeFragment_FamiliarInfo>(Stack.GetRuntimeFragment(UItemRuntimeFragment_FamiliarInfo));
        return Info != nullptr && Info.GetFamiliar() == nullptr;
    }

    // 0: level 9 and below, 1: 10-19, 2: 20 and above.
    int Tier(int Level)
    {
        if (Level <= 9)
            return 0;
        if (Level <= 19)
            return 1;
        return 2;
    }

    FName DustTag(int Tier)
    {
        if (Tier == 0)
            return n"Items.FeylightEssence"; // "Spirit Dust"
        if (Tier == 1)
            return n"Items.SpiritDustGreater";
        return n"Items.SpiritDustBrilliant";
    }

    FName EssenceTag(int Tier)
    {
        if (Tier == 0)
            return n"Items.Salvage_MagickEssenceLesser";
        if (Tier == 1)
            return n"Items.Salvage_MagickEssenceModerate"; // "Greater Magick Essence"
        return n"Items.Salvage_MagickEssenceGreater"; // "Brilliant Magick Essence"
    }

    // Common 1, Rare 2, Epic 3, Legendary 4.
    int RaritySteps(const UItemStack Stack)
    {
        return int(Stack.GetItemRarity()) + 1;
    }

    bool AddStack(TArray<UItemStack>& OutItems, AActor Owner, FName Tag, int Amount)
    {
        const UItemDefinition Def = UItemSubsystem::GetItemDefinition(FGameplayTag::RequestGameplayTag(Tag, false));
        if (Def == nullptr || Amount <= 0)
            return false;
        UItemStack Stack = UItemStack::CreateItemStack(Owner, Def, Amount);
        if (Stack == nullptr)
            return false;
        OutItems.Add(Stack);
        return true;
    }

    // Server, from ItemUtils::RollSalvageItemsFromItemStack.
    bool Roll(TArray<UItemStack>& OutItems, UItemStack Familiar)
    {
        if (!System::IsServer() || !Enabled())
            return false;
        UItemRuntimeFragment_FamiliarInfo Info = Cast<UItemRuntimeFragment_FamiliarInfo>(Familiar.GetRuntimeFragment(UItemRuntimeFragment_FamiliarInfo));
        if (Info == nullptr)
            return false;
        if (Info.GetFamiliar() != nullptr)
        {
            WSCoop::Info("Familiar salvage: skipped a familiar that is out in the world");
            return false;
        }
        AActor Owner = Familiar.GetOwningInventory() != nullptr ? Familiar.GetOwningInventory().GetOwner() : nullptr;
        const int Steps = RaritySteps(Familiar);
        const int T = Tier(Info.GetLevel());
        const bool bEssence = AddStack(OutItems, Owner, EssenceTag(T), Steps);
        const bool bDust = AddStack(OutItems, Owner, DustTag(T), Steps * 2);
        WSCoop::Info(f"Familiar salvage: level {Info.GetLevel()} rarity {Familiar.GetItemRarity()} -> {Steps}x {EssenceTag(T)}, {Steps * 2}x {DustTag(T)}");
        return bEssence && bDust;
    }
}

// A rolled set of stat lines waiting for the player's choice (server).
struct FWSPendingReroll
{
    UItemStack Weapon;
    AItemCraftingWorkstation Station;
    EItemRarity Rarity;
    TArray<FPassiveEffect> Effects;
};

UCLASS()
class UWSWorkstationExtras : UScriptWorldSubsystem
{
    private TMap<UObject, UFoundationButtonBase> RerollButtons;
    private TMap<APlayerController, FWSPendingReroll> Pending;
    private UItemCraftingWeaponCustomizationContentWidget PendingWidget;
    private AItemCraftingWorkstation PendingStation;
    private bool bFlagsSet = false;

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (bFlagsSet || !System::IsServer())
            return;
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr)
            return;
        Manager.bWeaponRerollEnabled = WSWeaponReroll::Enabled();
        Manager.bFamiliarSalvageEnabled = WSFamiliarSalvage::Enabled();
        bFlagsSet = true;
    }

    void AttachRerollButton(UItemCraftingWeaponCustomizationContentWidget Widget, UFoundationButtonBase Upgrade)
    {
        if (Widget == nullptr || Upgrade == nullptr || RerollButtons.Contains(Widget))
            return;
        // Upgrade sits in single-child boxes; go up to the panel that holds several things.
        UWidget Anchor = Upgrade;
        UPanelWidget Parent = Upgrade.GetParent();
        while (Parent != nullptr && Cast<UContentWidget>(Parent) != nullptr && Parent.GetParent() != nullptr)
        {
            Anchor = Parent;
            Parent = Parent.GetParent();
        }
        if (Parent == nullptr)
            return;
        UFoundationButtonBase Button = Cast<UFoundationButtonBase>(WidgetBlueprint::CreateWidget(Upgrade.Class, Gameplay::GetPlayerController(0)));
        if (Button == nullptr)
            return;
        UPanelSlot NewSlot = Parent.AddChild(Button);
        UVerticalBoxSlot V = Cast<UVerticalBoxSlot>(NewSlot);
        UVerticalBoxSlot AnchorV = Cast<UVerticalBoxSlot>(Anchor.Slot);
        if (V != nullptr && AnchorV != nullptr)
        {
            V.SetHorizontalAlignment(AnchorV.HorizontalAlignment);
            V.SetPadding(FMargin(AnchorV.Padding.Left, 8, AnchorV.Padding.Right, AnchorV.Padding.Bottom));
        }
        UHorizontalBoxSlot H = Cast<UHorizontalBoxSlot>(NewSlot);
        UHorizontalBoxSlot AnchorH = Cast<UHorizontalBoxSlot>(Anchor.Slot);
        if (H != nullptr && AnchorH != nullptr)
        {
            H.SetVerticalAlignment(AnchorH.VerticalAlignment);
            H.SetPadding(FMargin(8, AnchorH.Padding.Top, AnchorH.Padding.Right, AnchorH.Padding.Bottom));
        }
        UOverlaySlot O = Cast<UOverlaySlot>(NewSlot);
        UOverlaySlot AnchorO = Cast<UOverlaySlot>(Anchor.Slot);
        if (O != nullptr && AnchorO != nullptr)
        {
            O.SetHorizontalAlignment(AnchorO.HorizontalAlignment);
            O.SetVerticalAlignment(AnchorO.VerticalAlignment);
            O.SetPadding(FMargin(AnchorO.Padding.Left, AnchorO.Padding.Top, AnchorO.Padding.Right, AnchorO.Padding.Bottom + Anchor.GetDesiredSize().Y + 8));
        }
        UCanvasPanelSlot C = Cast<UCanvasPanelSlot>(NewSlot);
        UCanvasPanelSlot AnchorC = Cast<UCanvasPanelSlot>(Anchor.Slot);
        if (C != nullptr && AnchorC != nullptr)
        {
            C.SetAnchors(AnchorC.GetAnchors());
            C.SetAlignment(AnchorC.GetAlignment());
            C.SetAutoSize(true);
            C.SetPosition(AnchorC.GetPosition() + FVector2D(0, Anchor.GetDesiredSize().Y + 8));
        }
        Button.SetText(FText::FromString(f"Re-roll Stats ({WSWeaponReroll::DustCost} Brilliant Spirit Dust)"));
        Button.SetToolTipText(FText::FromString("Replace this weapon's stat lines with new random ones of the same rarity"));
        Button.OnButtonBaseClicked.AddUFunction(this, n"OnRerollClicked");
        Button.SetVisibility(ESlateVisibility::Collapsed);
        RerollButtons.Add(Widget, Button);
        WSCoop::Info(f"Weapon re-roll: button added ({Parent.Class.GetName()}, anchor {Anchor.Class.GetName()})");
    }

    void RefreshRerollButton(UItemCraftingWeaponCustomizationContentWidget Widget, AItemCraftingWorkstation Station, UItemStack Weapon)
    {
        UFoundationButtonBase Button;
        if (!RerollButtons.Find(Widget, Button) || !IsValid(Button))
            return;
        PendingWidget = Widget;
        PendingStation = Station;
        const bool bShow = WSWeaponReroll::ServerAllows() && WSWeaponReroll::CanReroll(Weapon);
        Button.SetVisibility(bShow ? ESlateVisibility::Visible : ESlateVisibility::Collapsed);
        if (bShow)
            Button.SetText(FText::FromString(f"Re-roll Stats ({WSWeaponReroll::DustCost} Brilliant Spirit Dust)"));
        // Developer test (-WSRerollTest): press it once, through the same network call as the confirm dialog.
        if (bShow && !bTestDone && System::ParseParam(System::GetCommandLine(), "WSRerollTest"))
        {
            bTestDone = true;
            WSCoop::Info("REROLLTEST pressing Re-roll Stats");
            System::SetTimer(this, n"RunTestReroll", 3.0, false);
        }
    }

    private bool bTestDone = false;

    UFUNCTION()
    private void RunTestReroll()
    {
        TestReroll();
    }

    UFUNCTION()
    private void OnRerollClicked(UCommonButtonBase Clicked)
    {
        if (PendingStation == nullptr)
            return;
        UItemStack Weapon = PendingStation.GetItemStackCraftingComponent().GetCurrentCraftingItemStack();
        if (!WSWeaponReroll::CanReroll(Weapon))
            return;
        if (Weapon.GetItemRarity() == EItemRarity::Common)
        {
            WSCoop::ShowLocalNotice("Re-roll Stats", "Common weapons have no stat lines to re-roll.");
            return;
        }
        const int Owned = WSWeaponReroll::DustOwned(PendingStation, Weapon);
        if (Owned < WSWeaponReroll::DustCost)
        {
            WSCoop::ShowLocalNotice("Re-roll Stats", f"You need {WSWeaponReroll::DustCost} Brilliant Spirit Dust (you have {Owned}).");
            return;
        }
        UClass ModalClass = Cast<UClass>(LoadObject(UClass, WSLuminaryRespec::ConfirmModalClassPath));
        if (ModalClass == nullptr || Game::GetHUD() == nullptr)
        {
            Confirmed(nullptr);
            return;
        }
        TSubclassOf<UHercActivatableWidget> WidgetClass = ModalClass;
        UConfirmModalWidget Modal = Cast<UConfirmModalWidget>(Game::GetHUD().PushWidgetToLayer(WidgetClass, EUILayer::MenuModal));
        if (Modal == nullptr)
            return;
        const UItemRuntimeFragment_Rarity Rarity = Weapon.GetRuntimeFragment_Rarity();
        Modal.WSSetTexts(FText::FromString("Re-roll this weapon's stats?"),
            FText::FromString(f"Spends {WSWeaponReroll::DustCost} Brilliant Spirit Dust now (you have {Owned}). You then see the new roll and choose to keep it or your current stats. The dust is spent either way.\nCurrent stats:\n{WSWeaponReroll::StatLines(Rarity)}"),
            FText::FromString("Re-roll"), FText::FromString("Cancel"));
        Modal.OnConfirmClickedDelegate.AddUFunction(this, n"Confirmed");
    }

    UFUNCTION()
    private void Confirmed(UCommonButtonBase Button)
    {
        APlayerController PC = Gameplay::GetPlayerController(0);
        if (PC == nullptr || PendingStation == nullptr)
            return;
        if (System::IsServer())
        {
            WSWeaponReroll::ServerReroll(PC, PendingStation);
            return;
        }
        UWSIdentityComponent Channel = WSIdentity::GetComponent(PC);
        if (Channel != nullptr)
            Channel.WSServerWeaponReroll(PendingStation);
    }

    // Tests: press the button's action without the modal.
    void TestReroll()
    {
        Confirmed(nullptr);
    }

    // ---- server: the roll waiting for the player's choice ----

    void SetPending(APlayerController PC, FWSPendingReroll Offer)
    {
        // A new roll replaces an unanswered one (that weapon keeps its current stats).
        Pending.Add(PC, Offer);
    }

    bool TakePending(APlayerController PC, FWSPendingReroll& Out)
    {
        if (!Pending.Find(PC, Out))
            return false;
        Pending.Remove(PC);
        return true;
    }

    FString PendingText(APlayerController PC)
    {
        FWSPendingReroll Offer;
        return Pending.Find(PC, Offer) ? WSWeaponReroll::EffectLines(Offer.Effects) : "";
    }

    // ---- client: keep the current stats or take the new roll ----

    private UConfirmModalWidget OfferModal;

    void ShowOffer(FString Current, FString New)
    {
        // A newer roll replaces one still on screen (the server already dropped that one).
        if (IsValid(OfferModal))
        {
            UConfirmModalWidget Old = OfferModal;
            OfferModal = nullptr;
            Old.DeactivateWidget();
        }
        WSCoop::Info("Weapon re-roll: offer shown");
        if (System::ParseParam(System::GetCommandLine(), "WSRerollTest"))
            System::SetTimer(this, n"TestTakeNew", 4.0, false); // developer test: take the new roll
        UClass ModalClass = Cast<UClass>(LoadObject(UClass, WSLuminaryRespec::ConfirmModalClassPath));
        if (ModalClass == nullptr || Game::GetHUD() == nullptr)
        {
            WSCoop::ShowLocalNotice("Stats Re-rolled", f"New roll (not applied):\n{New}");
            return;
        }
        TSubclassOf<UHercActivatableWidget> WidgetClass = ModalClass;
        OfferModal = Cast<UConfirmModalWidget>(Game::GetHUD().PushWidgetToLayer(WidgetClass, EUILayer::MenuModal));
        if (OfferModal == nullptr)
            return;
        OfferModal.WSSetTexts(FText::FromString("Keep the new roll?"),
            FText::FromString(f"Current stats:\n{Current}\n\nNew roll:\n{New}\n\nThe {WSWeaponReroll::DustCost} Brilliant Spirit Dust is already spent."),
            FText::FromString("Take New Roll"), FText::FromString("Keep Current"));
        OfferModal.OnConfirmClickedDelegate.AddUFunction(this, n"OfferTakeNew");
        OfferModal.OnCancelClickedDelegate.AddUFunction(this, n"OfferKeep");
    }

    UFUNCTION()
    private void TestTakeNew()
    {
        if (IsValid(OfferModal))
            OfferModal.DeactivateWidget();
        OfferTakeNew(nullptr);
    }

    UFUNCTION()
    private void OfferTakeNew(UCommonButtonBase Button)
    {
        if (OfferModal == nullptr)
            return; // already answered
        WSCoop::Info("Weapon re-roll: chose the new roll");
        OfferModal = nullptr;
        SendChoice(true);
    }

    UFUNCTION()
    private void OfferKeep(UCommonButtonBase Button)
    {
        if (OfferModal == nullptr)
            return;
        WSCoop::Info("Weapon re-roll: kept the current stats");
        OfferModal = nullptr;
        SendChoice(false);
    }

    private void SendChoice(bool bTakeNew)
    {
        APlayerController PC = Gameplay::GetPlayerController(0);
        if (PC == nullptr)
            return;
        if (System::IsServer())
        {
            WSWeaponReroll::ServerChoose(PC, bTakeNew);
            return;
        }
        UWSIdentityComponent Channel = WSIdentity::GetComponent(PC);
        if (Channel != nullptr)
            Channel.WSServerWeaponRerollChoice(bTakeNew);
    }
};
