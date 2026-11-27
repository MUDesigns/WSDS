// WitchspireCoopOverhaul - luminary respec.
//
// In the player's luminary menu and in a familiar's luminary menu:
//   - right-click an allocated luminary (gamepad: the UI "undo" action on the selected one) to take it back and
//     get its point back. A luminary that another allocated luminary still needs can't be taken back until
//     that one is (the menu says so); familiar luminaries that need a number of spent points work the same way.
//   - the UI "reset" action asks for confirmation, then takes back every luminary in that menu.
// Free luminaries granted by skill level-ups are never taken back. Respecs are free.
//
// How it works: spent points are derived from UProgressionComponent.GrantedUnlocks, so removing an entry
// refunds it. What a luminary granted (ability sets, gameplay effects) is remembered per grant on the server
// (GiveTracked, called from ProgressionComponent.UnlockGranted, which also runs for every saved luminary at
// load) and removed with the entry. Familiar abilities and passives also live on the familiar's item.
//
// ServerConfig.json -> "Coop" -> "LuminaryRespec" (default true).

USTRUCT()
struct FWSLuminaryGrant
{
    UPROPERTY()
    const UProgressionUnlockDefinition Unlock;

    UPROPERTY()
    bool bHasAbilitySet = false;

    UPROPERTY()
    FHercAbilitySet_GrantedHandles AbilityHandles;

    UPROPERTY()
    TArray<FActiveGameplayEffectHandle> Effects;
};

USTRUCT()
struct FWSLuminaryGrantList
{
    UPROPERTY()
    TArray<FWSLuminaryGrant> Grants;
};

// Server: what each progression component's luminaries granted. Client: which menus have respec actions.
UCLASS()
class UWSLuminaryRespecSubsystem : UScriptWorldSubsystem
{
    UPROPERTY()
    TMap<UProgressionComponent, FWSLuminaryGrantList> Granted;

    UPROPERTY()
    TSet<UObject> RegisteredPanels;

    void Add(UProgressionComponent Comp, const FWSLuminaryGrant& Grant)
    {
        if (Granted.Num() > 64)
            Prune();
        Granted.FindOrAdd(Comp).Grants.Add(Grant);
    }

    private void Prune()
    {
        TArray<UProgressionComponent> Dead;
        for (auto Entry : Granted)
        {
            if (!IsValid(Entry.Key))
                Dead.Add(Entry.Key);
        }
        for (UProgressionComponent C : Dead)
            Granted.Remove(C);
    }

    // Takes away what the most recent grant of Unlock gave.
    void Revoke(UProgressionComponent Comp, const UProgressionUnlockDefinition Unlock, UHercAbilityComponent AbilityComp)
    {
        if (!Granted.Contains(Comp) || AbilityComp == nullptr)
            return;
        FWSLuminaryGrantList& List = Granted[Comp];
        for (int Idx = List.Grants.Num() - 1; Idx >= 0; --Idx)
        {
            if (List.Grants[Idx].Unlock != Unlock)
                continue;
            if (List.Grants[Idx].bHasAbilitySet)
                AbilityComp.ClearAbilitySet(List.Grants[Idx].AbilityHandles);
            for (const FActiveGameplayEffectHandle& Effect : List.Grants[Idx].Effects)
                AbilityComp.RemoveActiveGameplayEffect(Effect);
            List.Grants.RemoveAt(Idx);
            return;
        }
    }

    // Returns true the first time a menu asks (so it binds its actions once).
    bool RegisterPanel(UObject Panel)
    {
        if (RegisteredPanels.Contains(Panel))
            return false;
        RegisteredPanels.Add(Panel);
        return true;
    }
};

namespace WSLuminaryRespec
{
    const FString ConfirmModalClassPath = "/Game/UserInterface/FrontEnd/MainMenu/ConfirmModal/WBP_ConfirmModal.WBP_ConfirmModal_C";
    const FString ResetActionPath = "/Game/UserInterface/Data/InputActions/IA_UI_Reset.IA_UI_Reset";
    const FString UndoActionPath = "/Game/UserInterface/Data/InputActions/IA_UI_Undo.IA_UI_Undo";

    bool Enabled() { return WSCoop::Flag("LuminaryRespec", true); }

    UWSLuminaryRespecSubsystem Tracker()
    {
        return UWSLuminaryRespecSubsystem::Get();
    }

    // Server, from UProgressionComponent::UnlockGranted: the vanilla grants, with their handles kept.
    void GiveTracked(UProgressionComponent Comp, UHercAbilityComponent AbilityComp, const UProgressionUnlockDefinition Unlock)
    {
        if (Unlock == nullptr || AbilityComp == nullptr)
            return;
        FWSLuminaryGrant Grant;
        Grant.Unlock = Unlock;
        Grant.bHasAbilitySet = Unlock.WSGiveAbilitySet(AbilityComp, Grant.AbilityHandles);
        Unlock.WSGiveGameplayEffect(AbilityComp, Grant.Effects);
        if (!Grant.bHasAbilitySet && Grant.Effects.Num() == 0)
            return;
        UWSLuminaryRespecSubsystem T = Tracker();
        if (T != nullptr)
            T.Add(Comp, Grant);
    }

    // Free luminaries handed out by skill level-ups.
    bool IsSkillReward(const APlayerCharacter Player, const UProgressionUnlockDefinition Unlock)
    {
        if (Player == nullptr || Unlock == nullptr)
            return false;
        UPlayerSkillsComponent Skills = UPlayerSkillsComponent::Get(Player);
        if (Skills == nullptr || Skills.SkillTemplates == nullptr)
            return false;
        for (auto Reward : Skills.SkillTemplates.InstantRewards)
        {
            for (auto Level : Reward.Value.LevelRewards)
            {
                if (Level.Value == Unlock)
                    return true;
            }
        }
        return false;
    }

    bool CanBeTakenBack(const APlayerCharacter Player, const UProgressionUnlockDefinition Unlock)
    {
        return Unlock != nullptr && Unlock.Type != EProgressionUnlockType::FamiliarAutoAttack && !IsSkillReward(Player, Unlock);
    }

    UItemRuntimeFragment_FamiliarActions FamiliarActions(const UProgressionComponent Comp)
    {
        ANPCBase Familiar = Cast<ANPCBase>(Comp.Owner);
        if (Familiar == nullptr)
            return nullptr;
        UItemStack Item = Familiar.GetAssociatedItem();
        return Item != nullptr ? Item.GetRuntimeFragment_FamiliarActions() : nullptr;
    }

    // "" = this player may respec that progression component (their own, or a familiar they carry).
    FString CheckAccess(APlayerCharacter Player, UProgressionComponent Comp)
    {
        if (!Enabled())
            return "Luminary respec is turned off on this server.";
        if (Player == nullptr || Comp == nullptr)
            return "Nothing to respec.";
        if (Comp.Owner == Player)
            return "";
        ANPCBase Familiar = Cast<ANPCBase>(Comp.Owner);
        if (Familiar != nullptr && Player.PlayerFamiliarComp != nullptr && Player.PlayerFamiliarComp.IsFamiliarInInventory(Familiar))
            return "";
        return "That isn't yours to respec.";
    }

    // Server: one luminary less (its grants, its familiar ability slot), point refunded.
    void TakeBackOne(APlayerCharacter Player, UProgressionComponent Comp, const UProgressionUnlockDefinition Unlock)
    {
        if (!Comp.WSRemoveUnlock(Unlock))
            return;
        UWSLuminaryRespecSubsystem T = Tracker();
        if (T != nullptr)
            T.Revoke(Comp, Unlock, UHercAbilityComponent::Get(Comp.Owner));

        if (Unlock.Type == EProgressionUnlockType::FamiliarAbility && Comp.WSCountGranted(Unlock) == 0)
        {
            UItemRuntimeFragment_FamiliarActions Actions = FamiliarActions(Comp);
            const EActionSlot Slot = Unlock.GetAbilitySlot();
            if (Actions != nullptr)
                Actions.UnlockedAbilities.Remove(Slot);
            ANPCBase Familiar = Cast<ANPCBase>(Comp.Owner);
            if (Familiar != nullptr && Player.PlayerFamiliarComp.GetCurrentFamiliar() == Familiar)
            {
                UActionComponent ActionComp = UActionComponent::Get(Player);
                if (ActionComp != nullptr)
                    ActionComp.ClearSingleActionSlot(int(Slot));
            }
        }
    }

    // Server: one stack less of a familiar passive (the equipped familiar's effect follows the new count).
    bool TakeBackPassiveStack(UProgressionComponent Comp, FGameplayTag PassiveTag)
    {
        UItemRuntimeFragment_FamiliarActions Actions = FamiliarActions(Comp);
        int Index = -1;
        if (Actions == nullptr || !PassiveTag.IsValid() || !Actions.TryFindPermanentPassiveIndex(PassiveTag, Index))
            return false;
        const int NewCount = Actions.PermanentPassives[Index].Count - 1;
        if (NewCount <= 0)
            Actions.PermanentPassives.RemoveAt(Index);
        else
            Actions.PermanentPassives[Index].Count = NewCount;
        Actions.OnFamiliarPassiveUnlocked.Broadcast(PassiveTag, Math::Max(NewCount, 0));
        return true;
    }

    // Server. "" on success, otherwise why not.
    FString Refund(APlayerCharacter Player, UProgressionComponent Comp, const UProgressionUnlockDefinition Unlock, FGameplayTag PassiveTag)
    {
        const FString Access = CheckAccess(Player, Comp);
        if (!Access.IsEmpty())
            return Access;
        if (Unlock == nullptr || Comp.WSCountGranted(Unlock) == 0)
            return "That luminary isn't allocated.";
        if (!CanBeTakenBack(Player, Unlock))
            return "That luminary was a free reward and can't be taken back.";
        if (Unlock.Type == EProgressionUnlockType::FamiliarPassive && !TakeBackPassiveStack(Comp, PassiveTag))
            return "That luminary isn't allocated.";
        TakeBackOne(Player, Comp, Unlock);
        Comp.WSClientRespecDone();
        WSCoop::Info(f"Luminary respec: {WSCoop::PlayerName(Player)} took back {Unlock.GetName()} on {Comp.Owner.GetName()} (unspent now {Comp.GetUnspentTechnologyPoints()})");
        return "";
    }

    // Server: takes back every luminary of that component. Returns how many points came back, -1 = refused.
    int ResetAll(APlayerCharacter Player, UProgressionComponent Comp, FString& OutWhy)
    {
        OutWhy = CheckAccess(Player, Comp);
        if (!OutWhy.IsEmpty())
            return -1;
        const int SpentBefore = Comp.GetSpentTechnologyPoints();
        TArray<const UProgressionUnlockDefinition> Unlocks = Comp.WSGetGrantedUnlocks();
        for (int Idx = Unlocks.Num() - 1; Idx >= 0; --Idx)
        {
            const UProgressionUnlockDefinition Unlock = Unlocks[Idx];
            if (Unlock == nullptr || !CanBeTakenBack(Player, Unlock))
                continue;
            TakeBackOne(Player, Comp, Unlock);
        }
        UItemRuntimeFragment_FamiliarActions Actions = FamiliarActions(Comp);
        if (Actions != nullptr)
        {
            TArray<FPermanentPassive> Passives = Actions.PermanentPassives;
            Actions.PermanentPassives.Empty();
            for (const FPermanentPassive& Passive : Passives)
                Actions.OnFamiliarPassiveUnlocked.Broadcast(Passive.PassiveTag, 0);
        }
        Comp.WSClientRespecDone();
        const int Refunded = SpentBefore - Comp.GetSpentTechnologyPoints();
        WSCoop::Info(f"Luminary respec: {WSCoop::PlayerName(Player)} reset {Comp.Owner.GetName()} ({Refunded} point(s) back, unspent now {Comp.GetUnspentTechnologyPoints()})");
        return Refunded;
    }

    // ---- server entry points (from UWSIdentityComponent RPCs, or directly on a host) ----

    void ServerRefund(APlayerController PC, UProgressionComponent Comp, const UProgressionUnlockDefinition Unlock, FGameplayTag PassiveTag)
    {
        APlayerCharacter Player = PC != nullptr ? Cast<APlayerCharacter>(PC.GetControlledPawn()) : nullptr;
        const FString Why = Refund(Player, Comp, Unlock, PassiveTag);
        if (!Why.IsEmpty())
            WSCoop::Notify(Player, Why);
    }

    void ServerReset(APlayerController PC, UProgressionComponent Comp)
    {
        APlayerCharacter Player = PC != nullptr ? Cast<APlayerCharacter>(PC.GetControlledPawn()) : nullptr;
        FString Why;
        const int Points = ResetAll(Player, Comp, Why);
        WSCoop::Notify(Player, Points < 0 ? Why : f"Luminaries reset: {Points} point(s) returned.");
    }

    // ---- client side (menus) ----

    void RequestRefund(UProgressionComponent Comp, const UProgressionUnlockDefinition Unlock, FGameplayTag PassiveTag)
    {
        APlayerController PC = Gameplay::GetPlayerController(0);
        if (PC == nullptr || Comp == nullptr || Unlock == nullptr)
            return;
        if (System::IsServer())
        {
            ServerRefund(PC, Comp, Unlock, PassiveTag);
            return;
        }
        UWSIdentityComponent Channel = WSIdentity::GetComponent(PC);
        if (Channel != nullptr)
            Channel.ServerWSLuminaryRefund(Comp, Unlock, PassiveTag);
        else
            WSCoop::ShowLocalMessage(FText::FromString("This server doesn't support luminary respec."));
    }

    void RequestReset(UProgressionComponent Comp)
    {
        APlayerController PC = Gameplay::GetPlayerController(0);
        if (PC == nullptr || Comp == nullptr)
            return;
        if (System::IsServer())
        {
            ServerReset(PC, Comp);
            return;
        }
        UWSIdentityComponent Channel = WSIdentity::GetComponent(PC);
        if (Channel != nullptr)
            Channel.ServerWSLuminaryReset(Comp);
        else
            WSCoop::ShowLocalMessage(FText::FromString("This server doesn't support luminary respec."));
    }

    UInputAction LoadAction(const FString& Path)
    {
        return Cast<UInputAction>(LoadObject(UInputAction, Path));
    }

    // Asks before a full reset; Confirmed is called on Target when the player agrees.
    UConfirmModalWidget AskResetConfirmation(UObject Target, FName Confirmed, bool bFamiliar)
    {
        UClass ModalClass = Cast<UClass>(LoadObject(UClass, ConfirmModalClassPath));
        if (ModalClass == nullptr || Game::GetHUD() == nullptr)
            return nullptr;
        TSubclassOf<UHercActivatableWidget> WidgetClass = ModalClass;
        UConfirmModalWidget Modal = Cast<UConfirmModalWidget>(Game::GetHUD().PushWidgetToLayer(WidgetClass, EUILayer::MenuModal));
        if (Modal == nullptr)
            return nullptr;
        Modal.WSSetTexts(
            FText::FromString(bFamiliar ? "Reset this familiar's luminaries?" : "Reset all your luminaries?"),
            FText::FromString("Every luminary in this menu is taken back and its points are returned to spend again. Skill rewards are kept."),
            FText::FromString("Reset"),
            FText::FromString("Cancel"));
        Modal.OnConfirmClickedDelegate.AddUFunction(Target, Confirmed);
        return Modal;
    }
}
