// Developer fixture for luminary respec (admin `lumtest ...`, only with -WSDevTools).
//   lumtest status <player> [fam]          points, allocated luminaries, tracked grants
//   lumtest grant <player> <n> [type]      allocate n affordable luminaries (type: skill|effect|tech|any)
//   lumtest refund <player> <name|last>    take one back
//   lumtest reset <player> [fam]           take all back
//   lumtest famgrant <player>              allocate the current familiar's first passive and slot-1 ability
//   lumtest famrefund <player>             take back one stack of that passive and the ability
namespace WSLuminaryRespecTest
{
    UProgressionComponent CompFor(APlayerCharacter P, bool bFamiliar)
    {
        if (!bFamiliar)
            return P.ProgressionComponent;
        ANPCBase Familiar = P.PlayerFamiliarComp.GetCurrentFamiliar();
        return Familiar != nullptr ? Familiar.ProgressionComponent : nullptr;
    }

    int TrackedGrants(UProgressionComponent Comp)
    {
        UWSLuminaryRespecSubsystem T = WSLuminaryRespec::Tracker();
        if (T == nullptr || !T.Granted.Contains(Comp))
            return 0;
        return T.Granted[Comp].Grants.Num();
    }

    FString Status(UProgressionComponent Comp)
    {
        if (Comp == nullptr)
            return "no progression component";
        FString Names = "";
        for (const UProgressionUnlockDefinition U : Comp.WSGetGrantedUnlocks())
            Names += (U != nullptr ? U.GetName().ToString() : "null") + ",";
        int ActiveEffects = 0;
        UHercAbilityComponent AC = UHercAbilityComponent::Get(Comp.Owner);
        FString Extra = "";
        UItemRuntimeFragment_FamiliarActions Actions = WSLuminaryRespec::FamiliarActions(Comp);
        if (Actions != nullptr)
        {
            Extra = f" abilities={Actions.UnlockedAbilities.Num()} passives=";
            for (const FPermanentPassive& P : Actions.PermanentPassives)
                Extra += f"{P.PassiveTag}x{P.Count};";
        }
        return f"{Comp.Owner.GetName()} level={Comp.GetCurrentLevel()} total={Comp.GetTotalTechnologyPoints()} spent={Comp.GetSpentTechnologyPoints()} unspent={Comp.GetUnspentTechnologyPoints()} tracked={TrackedGrants(Comp)}{Extra} unlocks=[{Names}]";
    }

    bool TypeMatches(const UProgressionUnlockDefinition U, const FString& Type)
    {
        if (Type == "skill")
            return U.Type == EProgressionUnlockType::Skill;
        if (Type == "effect")
            return U.Type == EProgressionUnlockType::GameplayEffect;
        if (Type == "tech")
            return U.Type == EProgressionUnlockType::Technology;
        return !ProgressionUnlockType::IsFamiliarUnlock(U.Type);
    }

    FString Run(const TArray<FString>& Args, APlayerCharacter P)
    {
        if (P == nullptr || Args.Num() < 2)
            return "FAIL no spawned player";
        const FString Action = Args[1];
        const bool bFam = Args.Num() >= 4 && Args[3] == "fam";
        if (Action == "status")
            return Status(CompFor(P, bFam));
        if (Action == "grant")
        {
            const int N = Args.Num() >= 4 ? String::Conv_StringToInt(Args[3]) : 1;
            const FString Type = Args.Num() >= 5 ? Args[4] : "any";
            UProgressionComponent Comp = P.ProgressionComponent;
            int Given = 0;
            for (const UProgressionUnlockDefinition U : UProgressionSubsystem::Get().GetUnlocks())
            {
                if (Given >= N)
                    break;
                if (U == nullptr || !TypeMatches(U, Type) || !Comp.CanPayUnlock(U) || WSLuminaryRespec::IsSkillReward(P, U))
                    continue;
                Comp.ServerGrantUnlock(U);
                Given++;
                WSCoop::Info(f"LUMTEST granted {U.GetName()} type={U.Type}");
            }
            return f"granted {Given}: {Status(Comp)}";
        }
        if (Action == "refund" && Args.Num() >= 4)
        {
            UProgressionComponent Comp = P.ProgressionComponent;
            TArray<const UProgressionUnlockDefinition> Granted = Comp.WSGetGrantedUnlocks();
            const UProgressionUnlockDefinition Target = nullptr;
            for (int i = Granted.Num() - 1; i >= 0 && Target == nullptr; --i)
            {
                if (Granted[i] != nullptr && (Args[3] == "last" || Granted[i].GetName().ToString() == Args[3]))
                    Target = Granted[i];
            }
            const FString Why = WSLuminaryRespec::Refund(P, Comp, Target, FGameplayTag());
            const FString TargetName = Target != nullptr ? Target.GetName().ToString() : "?";
            return Why.IsEmpty() ? f"refunded {TargetName}: {Status(Comp)}" : f"FAIL {Why}";
        }
        if (Action == "reset")
        {
            FString Why;
            const int Points = WSLuminaryRespec::ResetAll(P, CompFor(P, bFam), Why);
            return Points >= 0 ? f"reset, {Points} back: {Status(CompFor(P, bFam))}" : f"FAIL {Why}";
        }
        if (Action == "famgrant" || Action == "famrefund")
        {
            UProgressionComponent Comp = CompFor(P, true);
            UItemRuntimeFragment_FamiliarActions Actions = Comp != nullptr ? WSLuminaryRespec::FamiliarActions(Comp) : nullptr;
            if (Actions == nullptr)
                return "FAIL no current familiar";
            const UProgressionUnlockDefinition Passive = nullptr;
            const UProgressionUnlockDefinition Ability = nullptr;
            for (const UProgressionUnlockDefinition U : UProgressionSubsystem::Get().GetUnlocks())
            {
                if (U == nullptr)
                    continue;
                if (Passive == nullptr && U.Type == EProgressionUnlockType::FamiliarPassive && !U.FamiliarPredeterminedPassiveAbilityTag.IsValid())
                    Passive = U;
                if (Ability == nullptr && U.Type == EProgressionUnlockType::FamiliarAbility && U.GetAbilitySlot() == EActionSlot::FamiliarSlot1)
                    Ability = U;
            }
            FProgressionUnlockInstanceData Data;
            if (Actions.UnlockablePermanentPassives.Num() > 0)
                Data.FamiliarPassiveTag = Actions.UnlockablePermanentPassives[0];
            if (Action == "famgrant")
            {
                if (Passive != nullptr && Data.FamiliarPassiveTag.IsValid())
                    Comp.UnlockGranted(Passive, true, Data);
                if (Ability != nullptr && !Actions.IsAbilityUnlocked(EActionSlot::FamiliarSlot1))
                    Comp.UnlockGranted(Ability, true);
                const bool bP = Passive != nullptr;
                const bool bA = Ability != nullptr;
                return f"famgrant passive={bP} ability={bA}: {Status(Comp)}";
            }
            FString Out = "";
            if (Passive != nullptr)
                Out += "passive:" + WSLuminaryRespec::Refund(P, Comp, Passive, Data.FamiliarPassiveTag) + " ";
            if (Ability != nullptr)
                Out += "ability:" + WSLuminaryRespec::Refund(P, Comp, Ability, FGameplayTag()) + " ";
            return f"famrefund {Out}: {Status(Comp)}";
        }
        return "FAIL unknown action";
    }
}
