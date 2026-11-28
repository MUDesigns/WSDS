// WitchspireCoopOverhaul - quality of life (all on the player's own game, nothing new on the network):
//
// Split amount: the inventory's "Split" option opens a dialog with a slider and a number box to choose how many to
// take from the stack (1 to all but one; starts at half), instead of always taking half.
//
// Gear compare: an item tooltip for a weapon, hat, ring or trinket gets a "Compared to equipped" section: level,
// damage and rarity next to the equipped item in the same slot, and which stat lines would be gained or lost.
//
// Buff timers: a row under the compass shows the food and potion buffs on the player with the time left.

namespace WSQoL
{
    // Puts Widget right after Anchor in Parent. Scripts can't insert at an index, so in a vertical box the
    // children after the anchor are taken out and put back (keeping their slot settings).
    UPanelSlot InsertAfter(UPanelWidget Parent, UWidget Anchor, UWidget Widget)
    {
        UVerticalBox VBox = Cast<UVerticalBox>(Parent);
        const int At = Parent.GetChildIndex(Anchor);
        if (VBox == nullptr || At < 0)
            return Parent.AddChild(Widget);
        TArray<UWidget> After;
        TArray<FMargin> Paddings;
        TArray<EHorizontalAlignment> HAligns;
        TArray<EVerticalAlignment> VAligns;
        TArray<FSlateChildSize> Sizes;
        while (VBox.GetChildrenCount() > At + 1)
        {
            UWidget Child = VBox.GetChildAt(At + 1);
            UVerticalBoxSlot Old = Cast<UVerticalBoxSlot>(Child.Slot);
            After.Add(Child);
            Paddings.Add(Old != nullptr ? Old.Padding : FMargin());
            HAligns.Add(Old != nullptr ? Old.HorizontalAlignment : EHorizontalAlignment::HAlign_Fill);
            VAligns.Add(Old != nullptr ? Old.VerticalAlignment : EVerticalAlignment::VAlign_Fill);
            FSlateChildSize Auto;
            Auto.SizeRule = ESlateSizeRule::Automatic;
            Sizes.Add(Old != nullptr ? Old.Size : Auto);
            VBox.RemoveChildAt(At + 1);
        }
        UVerticalBoxSlot NewSlot = VBox.AddChildToVerticalBox(Widget);
        for (int i = 0; i < After.Num(); i++)
        {
            UVerticalBoxSlot Back = VBox.AddChildToVerticalBox(After[i]);
            Back.SetPadding(Paddings[i]);
            Back.SetHorizontalAlignment(HAligns[i]);
            Back.SetVerticalAlignment(VAligns[i]);
            Back.SetSize(Sizes[i]);
        }
        return NewSlot;
    }
}

namespace WSSplitStack
{
    const FString SliderClassPath = "/Game/UserInterface/FrontEnd/MainMenu/WBP_Slider.WBP_Slider_C";

    // From UInventoryWidget::GrabItemStackHalf (the "Split" menu option). False = fall back to taking half.
    bool Open(UInventoryWidget Widget, UItemStack Stack)
    {
        UWSQoLExtras Extras = UWSQoLExtras::Get();
        return Extras != nullptr && Extras.OpenSplit(Widget, Stack);
    }
}

namespace WSGearCompare
{
    // From UItemTooltipWidget::SetUserData (start: hide the old section; end: fill it for this item).
    void Clear(UItemTooltipWidget Tooltip)
    {
        UWSQoLExtras Extras = UWSQoLExtras::Get();
        if (Extras != nullptr)
            Extras.ClearCompare(Tooltip);
    }

    void Fill(UItemTooltipWidget Tooltip, const UItemStack Hovered)
    {
        UWSQoLExtras Extras = UWSQoLExtras::Get();
        if (Extras != nullptr)
            Extras.FillCompare(Tooltip, Hovered);
    }
}

namespace WSBuffTimers
{
    // Shorter effects (instant heals, 1-10 s snacks) get no timer.
    const float MinSeconds = 15.0;

    // From UConsumeAbility (runs on the player's game too): which item was just used, to name the buff it gives.
    void NoteConsumed(const UItemStack Stack)
    {
        UWSQoLExtras Extras = UWSQoLExtras::Get();
        if (Extras != nullptr && Stack != nullptr)
            Extras.NoteConsumed(Stack);
    }

    FString Clock(float Seconds)
    {
        const int Total = Math::CeilToInt(Math::Max(Seconds, 0.0));
        const int H = Math::IntegerDivisionTrunc(Total, 3600);
        const int M = Math::IntegerDivisionTrunc(Total, 60) % 60;
        const int S = Total % 60;
        const FString SS = S < 10 ? f"0{S}" : f"{S}";
        if (H > 0)
        {
            const FString MM = M < 10 ? f"0{M}" : f"{M}";
            return f"{H}:{MM}:{SS}";
        }
        return f"{M}:{SS}";
    }

    // "Effect.Exclusivity.BakedGoods" -> "Baked Goods".
    FString PrettyGroup(const FGameplayTag& Tag)
    {
        FString Name = Tag.ToString();
        int Dot = -1;
        if (Name.FindLastChar('.', Dot))
            Name = Name.RightChop(Dot + 1);
        FString Out;
        for (int i = 0; i < Name.Len(); i++)
        {
            const FString Ch = Name.Mid(i, 1);
            // (FString == ignores case, so compare case-sensitively.)
            const bool bUpper = Ch.Compare(Ch.ToUpper(), ESearchCase::CaseSensitive) == 0 && Ch.Compare(Ch.ToLower(), ESearchCase::CaseSensitive) != 0;
            const FString Prev = i > 0 ? Name.Mid(i - 1, 1) : "";
            const bool bPrevLower = i > 0 && Prev.Compare(Prev.ToLower(), ESearchCase::CaseSensitive) == 0 && Prev.Compare(Prev.ToUpper(), ESearchCase::CaseSensitive) != 0;
            if (i > 0 && bUpper && bPrevLower)
                Out += " ";
            Out += Ch;
        }
        return Out;
    }
}

// Where a status effect of a given group and length can come from (built from the item definitions).
struct FWSBuffSource
{
    FGameplayTag Item;
    bool bHidden = false;
};

struct FWSBuffSourceList
{
    TArray<FWSBuffSource> Sources;
};

struct FWSBuffShown
{
    int ID = 0;
    FString Name;
    FGameplayTag Icon;
    float EndServerTime = 0;
    bool bSkip = false;
};

UCLASS()
class UWSQoLExtras : UScriptWorldSubsystem
{
    // ---------------- split amount ----------------

    private UConfirmModalWidget SplitModal;
    private UInventoryWidget SplitWidget;
    private UItemStack SplitStack;
    private UHercSliderWidget SplitStyledSlider;
    private USlider SplitSlider;
    private UEditableTextBox SplitBox;
    private UTextBlock SplitInfo;
    private int SplitAmount = 1;
    private int SplitMax = 1;
    private bool bSplitSyncing = false;

    bool OpenSplit(UInventoryWidget Widget, UItemStack Stack)
    {
        if (Widget == nullptr || !IsValid(Stack) || Stack.GetStackSize() < 2)
            return false;
        UClass ModalClass = Cast<UClass>(LoadObject(UClass, WSLuminaryRespec::ConfirmModalClassPath));
        if (ModalClass == nullptr || Game::GetHUD() == nullptr)
            return false;
        TSubclassOf<UHercActivatableWidget> WidgetClass = ModalClass;
        UConfirmModalWidget Modal = Cast<UConfirmModalWidget>(Game::GetHUD().PushWidgetToLayer(WidgetClass, EUILayer::MenuModal));
        if (Modal == nullptr)
            return false;

        const int Size = Stack.GetStackSize();
        SplitModal = Modal;
        SplitWidget = Widget;
        SplitStack = Stack;
        SplitMax = Size - 1;
        SplitAmount = Math::Clamp(Math::IntegerDivisionTrunc(Size, 2), 1, SplitMax);
        Modal.WSSetTexts(FText::FromString(f"Split {Stack.GetDisplayName()}"),
            FText::FromString(f"How many to take from the stack of {Size}? Drag the slider or type a number."),
            FText::FromString("Split"), FText::FromString("Cancel"));

        // Slider and number box under the question.
        UVerticalBox Column = NewObject(Modal, UVerticalBox);
        UHorizontalBox Row = NewObject(Modal, UHorizontalBox);
        SplitStyledSlider = nullptr;
        SplitSlider = nullptr;
        UClass SliderClass = Cast<UClass>(LoadObject(UClass, WSSplitStack::SliderClassPath));
        if (SliderClass != nullptr)
            SplitStyledSlider = Cast<UHercSliderWidget>(WidgetBlueprint::CreateWidget(SliderClass, Gameplay::GetPlayerController(0)));
        UWidget SliderWidget;
        if (SplitStyledSlider != nullptr)
        {
            SplitStyledSlider.SliderWidth = 300;
            SplitSlider = SplitStyledSlider.SliderWidget;
            SliderWidget = SplitStyledSlider;
        }
        else
        {
            SplitSlider = NewObject(Modal, USlider);
            USizeBox SliderBox = NewObject(Modal, USizeBox);
            SliderBox.SetWidthOverride(300);
            SliderBox.SetContent(SplitSlider);
            SliderWidget = SliderBox;
        }
        SplitSlider.SetMinValue(1);
        SplitSlider.SetMaxValue(SplitMax);
        SplitSlider.SetStepSize(1);
        SplitSlider.SetValue(SplitAmount);
        if (SplitStyledSlider != nullptr)
            SplitStyledSlider.Refresh();
        SplitSlider.OnValueChanged.AddUFunction(this, n"SplitSliderChanged");
        Row.AddChildToHorizontalBox(SliderWidget).SetVerticalAlignment(EVerticalAlignment::VAlign_Center);

        SplitBox = NewObject(Modal, UEditableTextBox);
        SplitBox.SetText(FText::FromString(f"{SplitAmount}"));
        SplitBox.SetJustification(ETextJustify::Center);
        SplitBox.SetForegroundColor(FLinearColor(0.05, 0.04, 0.08, 1));
        SplitBox.OnTextChanged.AddUFunction(this, n"SplitTextChanged");
        SplitBox.OnTextCommitted.AddUFunction(this, n"SplitTextCommitted");
        USizeBox BoxSize = NewObject(Modal, USizeBox);
        BoxSize.SetWidthOverride(90);
        BoxSize.SetContent(SplitBox);
        UHorizontalBoxSlot BoxSlot = Row.AddChildToHorizontalBox(BoxSize);
        BoxSlot.SetPadding(FMargin(16, 0, 0, 0));
        BoxSlot.SetVerticalAlignment(EVerticalAlignment::VAlign_Center);
        Column.AddChildToVerticalBox(Row).SetHorizontalAlignment(EHorizontalAlignment::HAlign_Center);

        SplitInfo = NewObject(Modal, UTextBlock);
        TSubclassOf<UCommonTextStyle> Style = Cast<UClass>(LoadObject(UClass, WSMapMarkers::CompassLabelStylePath));
        if (Style != nullptr)
            SplitInfo.ApplyStyle(Style);
        SplitInfo.SetJustification(ETextJustify::Center);
        Column.AddChildToVerticalBox(SplitInfo).SetPadding(FMargin(0, 8, 0, 0));
        UpdateSplitInfo();

        UWidget Secondary = Modal.WSSecondaryText();
        UPanelWidget Parent = Secondary != nullptr ? Secondary.GetParent() : nullptr;
        if (Parent == nullptr)
        {
            Modal.DeactivateWidget();
            Modal.RemoveFromParent();
            return false;
        }
        const int At = Parent.GetChildIndex(Secondary);
        UPanelSlot NewSlot = WSQoL::InsertAfter(Parent, Secondary, Column);
        UVerticalBoxSlot V = Cast<UVerticalBoxSlot>(NewSlot);
        if (V != nullptr)
        {
            V.SetPadding(FMargin(0, 14, 0, 6));
            V.SetHorizontalAlignment(EHorizontalAlignment::HAlign_Center);
        }
        WSCoop::Info(f"Split dialog: {Stack.GetItemTag()} x{Size} (in {Parent.Class.GetName()} at {At + 1})");

        Modal.OnConfirmClickedDelegate.AddUFunction(this, n"SplitConfirmed");
        Modal.OnCancelClickedDelegate.AddUFunction(this, n"SplitCancelled");
        SplitBox.SetKeyboardFocus();
        return true;
    }

    private void SetSplitAmount(int Amount, bool bFromSlider, bool bFromBox)
    {
        SplitAmount = Math::Clamp(Amount, 1, SplitMax);
        bSplitSyncing = true;
        if (!bFromSlider && SplitSlider != nullptr)
        {
            SplitSlider.SetValue(SplitAmount);
            if (SplitStyledSlider != nullptr)
                SplitStyledSlider.Refresh();
        }
        if (!bFromBox && SplitBox != nullptr)
            SplitBox.SetText(FText::FromString(f"{SplitAmount}"));
        bSplitSyncing = false;
        UpdateSplitInfo();
    }

    private void UpdateSplitInfo()
    {
        if (SplitInfo == nullptr || !IsValid(SplitStack))
            return;
        const int Left = SplitStack.GetStackSize() - SplitAmount;
        SplitInfo.SetText(FText::FromString(f"Take {SplitAmount}, leave {Left}  (1 to {SplitMax})"));
    }

    UFUNCTION()
    private void SplitSliderChanged(float32 Value)
    {
        if (bSplitSyncing)
            return;
        SetSplitAmount(Math::RoundToInt(Value), true, false);
    }

    UFUNCTION()
    private void SplitTextChanged(const FText&in Text)
    {
        if (bSplitSyncing)
            return;
        const FString S = Text.ToString().TrimStartAndEnd();
        if (S.IsEmpty() || !S.IsNumeric())
            return;
        SetSplitAmount(String::Conv_StringToInt(S), false, true);
    }

    UFUNCTION()
    private void SplitTextCommitted(const FText&in Text, ETextCommit CommitMethod)
    {
        // Show the clamped number (typing 999 into a stack of 20 shows 19).
        SetSplitAmount(SplitAmount, false, false);
        if (CommitMethod == ETextCommit::OnEnter && IsValid(SplitModal))
        {
            UConfirmModalWidget Modal = SplitModal;
            SplitConfirmed(nullptr);
            Modal.DeactivateWidget();
            Modal.RemoveFromParent();
        }
    }

    UFUNCTION()
    private void SplitConfirmed(UCommonButtonBase Button)
    {
        if (SplitModal == nullptr)
            return; // already handled (Enter, then the button)
        SplitModal = nullptr;
        if (SplitWidget == nullptr || !IsValid(SplitStack))
            return;
        // The stack may have changed while the dialog was open.
        const int Amount = Math::Min(SplitAmount, SplitStack.GetStackSize() - 1);
        WSCoop::Info(f"Split dialog: take {Amount} of {SplitStack.GetStackSize()} {SplitStack.GetItemTag()}");
        if (Amount >= 1)
            SplitWidget.WSGrabAmount(SplitStack, Amount);
    }

    UFUNCTION()
    private void SplitCancelled(UCommonButtonBase Button)
    {
        SplitModal = nullptr;
    }

    // Tests (-WSSplitTest): type a number and press Split.
    void TestSplit(int Typed)
    {
        SplitTextChanged(FText::FromString(f"{Typed}"));
        SplitTextCommitted(FText::FromString(f"{Typed}"), ETextCommit::OnEnter);
    }

    // ---------------- gear compare ----------------

    private TMap<UObject, UVerticalBox> CompareBoxes;
    private TSubclassOf<UCommonTextStyle> CompareStyle;

    void ClearCompare(UItemTooltipWidget Tooltip)
    {
        UVerticalBox Box;
        if (Tooltip != nullptr && CompareBoxes.Find(Tooltip, Box) && IsValid(Box))
        {
            Box.ClearChildren();
            Box.SetVisibility(ESlateVisibility::Collapsed);
        }
    }

    // The equipped items a hovered item would replace. Weapons sit on the hotbar (the "hand" slot is just the selected
    // hotbar item), so a weapon is compared with the hotbar weapon of the same kind: the one in hand if it is that
    // kind, else the highest level one. Hats, rings and trinkets use their equipment slots (two for rings/trinkets).
    private TArray<UItemStack> EquippedFor(const UItemStack Hovered)
    {
        TArray<UItemStack> Out;
        APlayerCharacter Player = Cast<APlayerCharacter>(Gameplay::GetPlayerPawn(0));
        if (Player == nullptr || Hovered == nullptr || Hovered.ItemDefinition == nullptr)
            return Out;
        const UItemFragment_Equipment Equip = Hovered.ItemDefinition.GetFragment(UItemFragment_Equipment);
        if (Equip == nullptr || !Equip.EquipsToSlot.IsValid() || Equip.EquipsToSlot == GameplayTags::EquipmentSlot_Familiar)
            return Out;

        if (Equip.EquipsToSlot == GameplayTags::EquipmentSlot_Hand)
        {
            if (Hovered.GetRuntimeFragment_Weapon() == nullptr)
                return Out;
            const int HotbarSlots = Player.HotbarComp != nullptr ? Player.HotbarComp.GetSlotCount() : 0;
            UItemStack InHand = nullptr;
            UHercEquipmentInstance HandInstance = Player.EquipmentComp.GetEquipmentAtSlot(GameplayTags::EquipmentSlot_Hand);
            if (HandInstance != nullptr)
                InHand = HandInstance.ItemStack;
            UItemStack Best = nullptr;
            int BestLevel = -1;
            for (int Slot = 0; Slot < HotbarSlots; Slot++)
            {
                UItemStack S = Player.InventoryComp.GetItemStackAtSlot(Slot);
                if (S == nullptr)
                    continue;
                if (S == Hovered)
                    return Out; // hovering a hotbar weapon: it is already one of the equipped ones
                if (!SameWeaponKind(S, Equip))
                    continue;
                const UItemRuntimeFragment_Equipment Frag = S.GetRuntimeFragment_Equipment();
                int Level = Frag != nullptr ? Frag.ItemLevel : 0;
                if (S == InHand)
                    Level += 100000; // the weapon in hand wins
                if (Level > BestLevel)
                {
                    Best = S;
                    BestLevel = Level;
                }
            }
            if (Best != nullptr)
                Out.Add(Best);
            return Out;
        }

        TArray<FGameplayTag> Slots;
        if (Equip.EquipsToSlot == GameplayTags::EquipmentSlot_Ring)
        {
            Slots.Add(GameplayTags::EquipmentSlot_Ring_1);
            Slots.Add(GameplayTags::EquipmentSlot_Ring_2);
        }
        else if (Equip.EquipsToSlot == GameplayTags::EquipmentSlot_Trinket)
        {
            Slots.Add(GameplayTags::EquipmentSlot_Trinket_1);
            Slots.Add(GameplayTags::EquipmentSlot_Trinket_2);
        }
        else
            Slots.Add(Equip.EquipsToSlot);
        for (const FGameplayTag& SlotTag : Slots)
        {
            UHercEquipmentInstance Instance = Player.EquipmentComp.GetEquipmentAtSlot(SlotTag);
            if (Instance == nullptr || Instance.ItemStack == nullptr)
                continue;
            if (Instance.ItemStack == Hovered)
            {
                Out.Empty(); // hovering an equipped item: nothing to compare
                return Out;
            }
            Out.Add(Instance.ItemStack);
        }
        return Out;
    }

    private bool SameWeaponKind(const UItemStack Stack, const UItemFragment_Equipment HoveredEquip) const
    {
        if (Stack.GetRuntimeFragment_Weapon() == nullptr || Stack.ItemDefinition == nullptr)
            return false;
        const UItemFragment_Equipment Other = Stack.ItemDefinition.GetFragment(UItemFragment_Equipment);
        return Other != nullptr && Other.ActionSequenceType == HoveredEquip.ActionSequenceType;
    }

    void FillCompare(UItemTooltipWidget Tooltip, const UItemStack Hovered)
    {
        if (Tooltip == nullptr || Hovered == nullptr)
            return;
        TArray<UItemStack> Equipped = EquippedFor(Hovered);
        if (Equipped.IsEmpty())
            return;
        UVerticalBox Box = CompareBox(Tooltip);
        if (Box == nullptr)
            return;
        Box.ClearChildren();
        for (UItemStack Other : Equipped)
            AddComparison(Box, Hovered, Other);
        Box.SetVisibility(ESlateVisibility::HitTestInvisible);
    }

    private UVerticalBox CompareBox(UItemTooltipWidget Tooltip)
    {
        UVerticalBox Box;
        if (CompareBoxes.Find(Tooltip, Box) && IsValid(Box))
            return Box;
        UWidget Footer = Tooltip.Text_Description_Footer;
        UPanelWidget Parent = Footer != nullptr ? Footer.GetParent() : nullptr;
        if (Parent == nullptr)
            return nullptr;
        Box = NewObject(Tooltip, UVerticalBox);
        UPanelSlot NewSlot = WSQoL::InsertAfter(Parent, Footer, Box);
        UVerticalBoxSlot V = Cast<UVerticalBoxSlot>(NewSlot);
        if (V != nullptr)
            V.SetPadding(FMargin(0, 10, 0, 0));
        CompareBoxes.Add(Tooltip, Box);
        if (CompareStyle == nullptr)
            CompareStyle = Cast<UClass>(LoadObject(UClass, WSMapMarkers::CompassLabelStylePath));
        WSCoop::Info(f"Gear compare: section added to a tooltip ({Parent.Class.GetName()})");
        return Box;
    }

    private void Line(UVerticalBox Box, const FString& Text, FLinearColor Color, float Top = 2)
    {
        UTextBlock T = NewObject(Box, UTextBlock);
        if (CompareStyle != nullptr)
            T.ApplyStyle(CompareStyle);
        T.SetText(FText::FromString(Text));
        T.SetColorAndOpacity(FSlateColor(Color));
        Box.AddChildToVerticalBox(T).SetPadding(FMargin(0, Top, 0, 0));
    }

    private FLinearColor Better() const { return FLinearColor(0.55, 0.95, 0.5, 1); }
    private FLinearColor Worse() const { return FLinearColor(1.0, 0.45, 0.4, 1); }
    private FLinearColor Same() const { return FLinearColor(0.75, 0.72, 0.8, 1); }
    private FLinearColor Heading() const { return FLinearColor(1.0, 0.85, 0.45, 1); }

    private FString Signed(int Delta) const
    {
        return Delta > 0 ? f"+{Delta}" : f"{Delta}";
    }

    private void AddComparison(UVerticalBox Box, const UItemStack Hovered, const UItemStack Other)
    {
        Line(Box, f"Compared to equipped {Other.GetDisplayName()}:", Heading(), Box.GetChildrenCount() > 0 ? 10 : 0);

        const UItemRuntimeFragment_Equipment A = Hovered.GetRuntimeFragment_Equipment();
        const UItemRuntimeFragment_Equipment B = Other.GetRuntimeFragment_Equipment();
        if (A != nullptr && B != nullptr)
        {
            const int LevelA = A.ItemLevel;
            const int LevelB = B.ItemLevel;
            const int DLevel = LevelA - LevelB;
            Line(Box, DLevel == 0 ? f"Level {LevelA} (same)" : f"Level {LevelB} -> {LevelA} ({Signed(DLevel)})",
                DLevel > 0 ? Better() : (DLevel < 0 ? Worse() : Same()));
            const bool bWeapons = Hovered.GetRuntimeFragment_Weapon() != nullptr && Other.GetRuntimeFragment_Weapon() != nullptr;
            if (bWeapons)
            {
                const int DamageA = Math::RoundToInt(UActionSettings.DefaultObject.GetAverageDamagePerSecond(LevelA));
                const int DamageB = Math::RoundToInt(UActionSettings.DefaultObject.GetAverageDamagePerSecond(LevelB));
                const int DDamage = DamageA - DamageB;
                Line(Box, DDamage == 0 ? f"Damage {DamageA} (same)" : f"Damage {DamageB} -> {DamageA} ({Signed(DDamage)})",
                    DDamage > 0 ? Better() : (DDamage < 0 ? Worse() : Same()));
            }
        }

        const UItemRuntimeFragment_Rarity RA = Hovered.GetRuntimeFragment_Rarity();
        const UItemRuntimeFragment_Rarity RB = Other.GetRuntimeFragment_Rarity();
        if (RA == nullptr && RB == nullptr)
            return;
        const int RarityA = RA != nullptr ? int(RA.GetRarity()) : 0;
        const int RarityB = RB != nullptr ? int(RB.GetRarity()) : 0;
        if (RarityA != RarityB)
            Line(Box, f"Rarity {RarityName(RarityB)} -> {RarityName(RarityA)}", RarityA > RarityB ? Better() : Worse());

        TArray<FString> LinesA = StatLineTexts(RA);
        TArray<FString> LinesB = StatLineTexts(RB);
        TArray<FString> Gained;
        TArray<FString> Lost;
        TArray<FString> RestB = LinesB;
        for (const FString& L : LinesA)
        {
            const int Found = RestB.FindIndex(L);
            if (Found >= 0)
                RestB.RemoveAt(Found);
            else
                Gained.Add(L);
        }
        Lost = RestB;
        if (Gained.IsEmpty() && Lost.IsEmpty())
        {
            if (!LinesA.IsEmpty())
                Line(Box, "Same stat lines", Same());
            return;
        }
        for (const FString& L : Gained)
            Line(Box, f"Gain: {L}", Better());
        for (const FString& L : Lost)
            Line(Box, f"Lose: {L}", Worse());
    }

    private TArray<FString> StatLineTexts(const UItemRuntimeFragment_Rarity Rarity) const
    {
        TArray<FString> Out;
        if (Rarity == nullptr)
            return Out;
        for (const FPassiveEffect& Effect : Rarity.RarityEffects)
            Out.Add(Effect.GetLocalizedText().ToString());
        return Out;
    }

    private FString RarityName(int Rarity) const
    {
        if (Rarity <= 0)
            return "Common";
        if (Rarity == 1)
            return "Rare";
        if (Rarity == 2)
            return "Epic";
        return "Legendary";
    }

    // ---------------- buff timers ----------------

    private TMap<FString, FWSBuffSourceList> BuffSources;
    private bool bSourcesBuilt = false;
    private FGameplayTag LastConsumed;
    private float LastConsumedTime = -100;
    private TMap<int, FWSBuffShown> Shown;
    private UHUDWidget BuffHUD;
    private UHorizontalBox BuffRow;
    private TArray<int> RowIDs;
    private TArray<UTextBlock> RowTexts;
    private TSubclassOf<UCommonTextStyle> BuffStyle;
    private float BuffClock = 0;

    void NoteConsumed(const UItemStack Stack)
    {
        APawn Local = Gameplay::GetPlayerPawn(0);
        UInventoryComponent Inventory = Stack.GetOwningInventory();
        if (Local == nullptr || (Inventory != nullptr && Inventory.GetOwner() != Local))
            return;
        LastConsumed = Stack.GetItemTag();
        LastConsumedTime = Game::GetWorldTimeSeconds();
    }

    private FString SourceKey(const FGameplayTag& Group, float Duration) const
    {
        return f"{Group}|{Math::RoundToInt(Duration * 10)}";
    }

    private void BuildSources()
    {
        bSourcesBuilt = true;
        UItemSubsystem Items = UItemSubsystem::Get();
        if (Items == nullptr)
            return;
        for (auto Pair : Items.Items)
        {
            const UItemDefinition Def = Pair.Value;
            if (Def == nullptr)
                continue;
            const UItemFragment_StatusEffects SE = Def.GetFragment(UItemFragment_StatusEffects);
            if (SE == nullptr)
                continue;
            for (const FStatusEffect& E : SE.Effects)
            {
                FWSBuffSource Source;
                Source.Item = Pair.Key;
                Source.bHidden = E.bHideFromUI;
                const FString Key = SourceKey(E.Exclusivity, E.Duration);
                FWSBuffSourceList List;
                BuffSources.Find(Key, List);
                List.Sources.Add(Source);
                BuffSources.Add(Key, List);
            }
        }
    }

    // Names a new effect: the item just used if it gives this kind of effect, else the only item that does,
    // else the effect group's name. Hidden helper effects and effects no item gives get no timer.
    private FWSBuffShown Describe(const FActiveStatusEffect& Effect, float ServerNow)
    {
        FWSBuffShown Out;
        Out.ID = Effect.ID;
        Out.EndServerTime = Effect.AddedTime + Effect.Duration;
        FWSBuffSourceList Sources;
        BuffSources.Find(SourceKey(Effect.Exclusivity, Effect.Duration), Sources);
        TArray<FWSBuffSource> Visible;
        bool bJustUsed = false;
        for (const FWSBuffSource& S : Sources.Sources)
        {
            if (S.bHidden)
                continue;
            Visible.Add(S);
            if (S.Item == LastConsumed && Game::GetWorldTimeSeconds() - LastConsumedTime < 5.0)
                bJustUsed = true;
        }
        if (Visible.IsEmpty())
        {
            Out.bSkip = true;
            return Out;
        }
        FGameplayTag Item;
        if (bJustUsed)
            Item = LastConsumed;
        else if (Visible.Num() == 1)
            Item = Visible[0].Item;
        if (Item.IsValid())
        {
            const UItemDefinition Def = UItemSubsystem::GetItemDefinition(Item);
            Out.Name = Def != nullptr ? Def.DisplayName.ToString() : Item.ToString();
            Out.Icon = Item;
        }
        else
        {
            Out.Name = Effect.Exclusivity.IsValid() ? WSBuffTimers::PrettyGroup(Effect.Exclusivity) : "Buff";
            Out.Icon = Visible[0].Item;
        }
        return Out;
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        BuffClock += DeltaTime;
        if (BuffClock < 0.25)
            return;
        BuffClock = 0;
        if (WSDS::IsHeadlessHost())
            return;
        TickBuffs();
        TickTests();
    }

    // The game's world time is kept in step with the server and is what status effects are stamped with
    // (FActiveStatusEffect::RemainingTime uses it too); the engine's server clock is a different time base.
    private float ServerTime() const
    {
        return Game::GetWorldTimeSeconds();
    }

    private void TickBuffs()
    {
        APawn Pawn = Gameplay::GetPlayerPawn(0);
        UStatusEffectComponent Effects = Pawn != nullptr ? UStatusEffectComponent::Get(Pawn) : nullptr;
        UHUDWidget HUD = Game::GetHUDWidget();
        if (Effects == nullptr || HUD == nullptr)
        {
            if (BuffRow != nullptr && IsValid(BuffRow))
                BuffRow.SetVisibility(ESlateVisibility::Collapsed);
            return;
        }
        if (!bSourcesBuilt)
            BuildSources();
        const float Now = ServerTime();

        // Current timed effects, oldest first.
        TArray<int> Live;
        for (const FActiveStatusEffect& Effect : Effects.GetActiveStatusEffects())
        {
            if (Effect.Duration < WSBuffTimers::MinSeconds)
                continue;
            if (!Shown.Contains(Effect.ID))
                Shown.Add(Effect.ID, Describe(Effect, Now));
            FWSBuffShown Info = Shown[Effect.ID];
            if (Info.bSkip || Info.EndServerTime - Now <= 0)
                continue;
            Live.Add(Effect.ID);
        }
        // Forget effects that ended.
        TArray<int> Old;
        for (auto Pair : Shown)
        {
            bool bActive = false;
            for (const FActiveStatusEffect& Effect : Effects.GetActiveStatusEffects())
            {
                if (Effect.ID == Pair.Key)
                    bActive = true;
            }
            if (!bActive)
                Old.Add(Pair.Key);
        }
        for (int ID : Old)
            Shown.Remove(ID);

        if (BuffHUD != HUD || BuffRow == nullptr || !IsValid(BuffRow))
            BuildBuffRow(HUD);
        if (BuffRow == nullptr)
            return;
        if (Live != RowIDs)
            FillBuffRow(Live);
        for (int i = 0; i < RowIDs.Num() && i < RowTexts.Num(); i++)
        {
            FWSBuffShown Info = Shown[RowIDs[i]];
            const float Left = Info.EndServerTime - Now;
            RowTexts[i].SetText(FText::FromString(f"{Info.Name}  {WSBuffTimers::Clock(Left)}"));
            RowTexts[i].SetColorAndOpacity(FSlateColor(Left < 30 ? FLinearColor(1.0, 0.7, 0.35, 1) : FLinearColor(0.92, 0.9, 0.98, 1)));
        }
        BuffRow.SetVisibility(RowIDs.IsEmpty() ? ESlateVisibility::Collapsed : ESlateVisibility::HitTestInvisible);
    }

    private void BuildBuffRow(UHUDWidget HUD)
    {
        BuffHUD = HUD;
        BuffRow = nullptr;
        RowIDs.Empty();
        RowTexts.Empty();
        UPanelWidget Root = Cast<UPanelWidget>(HUD.GetRootWidget());
        if (Root == nullptr)
            return;
        BuffStyle = Cast<UClass>(LoadObject(UClass, WSMapMarkers::CompassLabelStylePath));
        BuffRow = NewObject(HUD, UHorizontalBox);
        UPanelSlot RowSlot = Root.AddChild(BuffRow);
        UCanvasPanelSlot AsCanvas = Cast<UCanvasPanelSlot>(RowSlot);
        UOverlaySlot AsOverlay = Cast<UOverlaySlot>(RowSlot);
        if (AsCanvas != nullptr)
        {
            FAnchors Anchors;
            Anchors.Minimum = FVector2D(0.5, 0.0);
            Anchors.Maximum = FVector2D(0.5, 0.0);
            AsCanvas.SetAnchors(Anchors);
            AsCanvas.SetAlignment(FVector2D(0.5, 0.0));
            AsCanvas.SetAutoSize(true);
            AsCanvas.SetPosition(FVector2D(0, 196));
            AsCanvas.SetZOrder(40);
        }
        else if (AsOverlay != nullptr)
        {
            AsOverlay.SetHorizontalAlignment(EHorizontalAlignment::HAlign_Center);
            AsOverlay.SetVerticalAlignment(EVerticalAlignment::VAlign_Top);
            AsOverlay.SetPadding(FMargin(0, 196, 0, 0));
        }
        BuffRow.SetVisibility(ESlateVisibility::Collapsed);
        WSCoop::Info(f"Buff timers: row added to the HUD ({Root.Class.GetName()})");
    }

    private void FillBuffRow(const TArray<int>& Live)
    {
        BuffRow.ClearChildren();
        RowIDs = Live;
        RowTexts.Empty();
        for (int ID : Live)
        {
            FWSBuffShown Info = Shown[ID];
            UBorder Chip = NewObject(BuffRow, UBorder);
            Chip.SetBrushColor(FLinearColor(0.03, 0.02, 0.07, 0.7));
            Chip.SetPadding(FMargin(6, 3, 10, 3));
            UHorizontalBox Content = NewObject(BuffRow, UHorizontalBox);
            const UItemDefinition Def = Info.Icon.IsValid() ? UItemSubsystem::GetItemDefinition(Info.Icon) : nullptr;
            if (Def != nullptr)
            {
                UCommonLazyImage Icon = NewObject(BuffRow, UCommonLazyImage);
                Icon.SetBrushFromLazyDisplayAsset(Def.Icon.Image);
                USizeBox IconBox = NewObject(BuffRow, USizeBox);
                IconBox.SetWidthOverride(26);
                IconBox.SetHeightOverride(26);
                IconBox.SetContent(Icon);
                Content.AddChildToHorizontalBox(IconBox).SetVerticalAlignment(EVerticalAlignment::VAlign_Center);
            }
            UTextBlock Text = NewObject(BuffRow, UTextBlock);
            if (BuffStyle != nullptr)
                Text.ApplyStyle(BuffStyle);
            Text.SetShadowOffset(FVector2D(1, 1));
            Text.SetShadowColorAndOpacity(FLinearColor(0, 0, 0, 0.9));
            UHorizontalBoxSlot TextSlot = Content.AddChildToHorizontalBox(Text);
            TextSlot.SetVerticalAlignment(EVerticalAlignment::VAlign_Center);
            TextSlot.SetPadding(FMargin(6, 0, 0, 0));
            Chip.SetContent(Content);
            BuffRow.AddChildToHorizontalBox(Chip).SetPadding(FMargin(4, 0, 4, 0));
            RowTexts.Add(Text);
        }
        if (!Live.IsEmpty())
            WSCoop::Info(f"Buff timers: showing {Live.Num()} buff(s)");
    }

    // ---------------- developer tests (client switches, need -WSDevTools on the server side only for items) ----------------

    private int TestStage = 0;
    private float TestClock = 0;

    private void TickTests()
    {
        if (TestStage < 0)
            return;
        const FString Cmd = System::GetCommandLine();
        const bool bSplit = System::ParseParam(Cmd, "WSSplitTest");
        const bool bCompare = System::ParseParam(Cmd, "WSCompareTest");
        if (!bSplit && !bCompare)
        {
            TestStage = -1;
            return;
        }
        TestClock += 0.25;
        APlayerCharacter Player = Cast<APlayerCharacter>(Gameplay::GetPlayerPawn(0));
        AHercHUD HUD = Cast<AHercHUD>(Game::GetHUD());
        if (Player == nullptr || HUD == nullptr || TestClock < 20)
            return;
        if (bSplit && TestStage == 0)
        {
            for (int Slot = 0; Slot < Player.InventoryComp.GetCapacity(); Slot++)
            {
                UItemStack S = Player.InventoryComp.GetItemStackAtSlot(Slot);
                if (S != nullptr && S.GetStackSize() >= 6 && S.GetRuntimeFragment_Rarity() == nullptr)
                {
                    WSCoop::Info(f"SPLITTEST opening for {S.GetItemTag()} x{S.GetStackSize()}");
                    TestStage = 1;
                    UInventoryWidget Widget = HUD.Widget_PlayerInventory;
                    if (Widget == nullptr || !OpenSplit(Widget, S))
                        WSCoop::Info("SPLITTEST FAIL could not open");
                    TestStage = 1;
                    TestClock = 20;
                    TestSplitStack = S;
                    TestSplitBefore = S.GetStackSize();
                    return;
                }
            }
            WSCoop::Info("SPLITTEST FAIL no stack of 6+ in the bag");
            TestStage = -1;
            return;
        }
        if (bSplit && TestStage == 1 && TestClock >= 26)
        {
            TestSplit(3);
            TestStage = 2;
            TestClock = 20;
            return;
        }
        if (bSplit && TestStage == 2 && TestClock >= 23)
        {
            UItemStack Grabbed = HUD.GetGrabbedItem();
            const int Left = IsValid(TestSplitStack) ? TestSplitStack.GetStackSize() : -1;
            const int GrabbedSize = Grabbed != nullptr ? Grabbed.GetStackSize() : 0;
            WSCoop::Info(f"SPLITTEST result: stack {TestSplitBefore} -> {Left}, grabbed {GrabbedSize}");
            TestStage = -1;
            return;
        }
        if (bCompare && TestStage == 0)
        {
            TestStage = -1;
            UItemStack Candidate = nullptr;
            for (int Slot = 0; Slot < Player.InventoryComp.GetCapacity(); Slot++)
            {
                UItemStack S = Player.InventoryComp.GetItemStackAtSlot(Slot);
                if (S != nullptr && !EquippedFor(S).IsEmpty())
                    Candidate = S;
            }
            if (Candidate == nullptr)
            {
                WSCoop::Info("COMPARETEST FAIL nothing in the bag to compare with equipped gear");
                return;
            }
            UClass TooltipClass = Cast<UClass>(LoadObject(UClass, "/Game/UserInterface/Crafting/Inventory/WBP_ItemTooltipWidget.WBP_ItemTooltipWidget_C"));
            UItemTooltipWidget Tooltip = TooltipClass != nullptr ? Cast<UItemTooltipWidget>(WidgetBlueprint::CreateWidget(TooltipClass, Gameplay::GetPlayerController(0))) : nullptr;
            if (Tooltip == nullptr)
            {
                WSCoop::Info("COMPARETEST FAIL no tooltip widget");
                return;
            }
            Tooltip.AddToViewport(500);
            Tooltip.SetUserData(Candidate);
            UVerticalBox Box;
            const int Lines = CompareBoxes.Find(Tooltip, Box) ? Box.GetChildrenCount() : -1;
            WSCoop::Info(f"COMPARETEST tooltip for {Candidate.GetItemTag()}: {Lines} compare lines");
        }
    }

    private UItemStack TestSplitStack;
    private int TestSplitBefore = 0;
};
