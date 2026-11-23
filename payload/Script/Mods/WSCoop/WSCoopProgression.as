// WitchspireCoopOverhaul - catch-up scaling and coven synergy.
//
// Catch-up (CatchUpXP): a player below the highest-level character currently online earns more kill XP:
//     multiplier = clamp(1 + CatchUpPerLevel * levelsBehind, 1, CatchUpMaxMultiplier)
// Coven synergy (CovenSynergy): for every other coven member within CovenRange:
//     * +CovenBonusPerMember kill XP and skill XP (gathering, crafting, taming, ...)
//     * nearby members receive CovenSkillShare of the skill XP a member earns, so specialists level the party
//     * harvesting gets a CovenBonusPerMember chance per nearby member of one extra loot roll

namespace WSCoopProgression
{
    float CovenSkillShare() { return WSCoop::Number("CovenSkillShare", 0.25); }

    int GetLevel(const APlayerCharacter Player)
    {
        if (Player == nullptr || Player.AbilityComp == nullptr)
            return 1;
        return int(Player.AbilityComp.GetLevel());
    }

    int HighestOnlineLevel()
    {
        int Highest = 1;
        for (APlayerCharacter P : WSCoop::GetPlayers())
            Highest = Math::Max(Highest, GetLevel(P));
        return Highest;
    }

    TArray<APlayerCharacter> NearbyMembers(const APlayerCharacter Player)
    {
        TArray<APlayerCharacter> Result;
        if (Player == nullptr)
            return Result;
        TArray<APlayerCharacter> InRange;
        ExperienceShare::GetPlayersInRadius(Player.GetActorLocation(), WSCoop::CovenRange(), InRange);
        for (APlayerCharacter Other : InRange)
        {
            if (Other != Player && Other.IsAlive())
                Result.Add(Other);
        }
        return Result;
    }

    float CatchUpMultiplier(const APlayerCharacter Player)
    {
        if (!WSCoop::CatchUpXP() || Player == nullptr)
            return 1.0;
        const int Behind = HighestOnlineLevel() - GetLevel(Player);
        if (Behind <= 0)
            return 1.0;
        return Math::Clamp(1.0 + WSCoop::CatchUpPerLevel() * Behind, 1.0, WSCoop::CatchUpMaxMultiplier());
    }

    float SynergyMultiplier(const APlayerCharacter Player)
    {
        if (!WSCoop::CovenSynergy() || Player == nullptr)
            return 1.0;
        return 1.0 + WSCoop::CovenBonusPerMember() * NearbyMembers(Player).Num();
    }

    // Kill XP (ExperienceShare::GrantExperienceToPlayerAndFamiliar).
    float KillXPMultiplier(const APlayerCharacter Player)
    {
        if (!System::IsServer())
            return 1.0;
        const float CatchUp = CatchUpMultiplier(Player);
        const float Synergy = SynergyMultiplier(Player);
        if (CatchUp > 1.0 || Synergy > 1.0)
            WSCoop::Info(f"XP bonus for {WSCoop::PlayerName(Player)}: catch-up x{CatchUp} synergy x{Synergy}");
        return CatchUp * Synergy;
    }

    // Skill XP (UPlayerSkillsComponent::OnTaskUpdated).
    float SkillXPMultiplier(const APlayerCharacter Player)
    {
        if (!System::IsServer())
            return 1.0;
        return SynergyMultiplier(Player);
    }

    // After a member earns skill XP, share a part of it with nearby coven members.
    void ShareSkillXP(const APlayerCharacter Earner, FGameplayTag SkillTag, float XP)
    {
        if (!System::IsServer() || !WSCoop::CovenSynergy() || XP <= 0)
            return;
        const float Share = XP * CovenSkillShare();
        if (Share <= 0)
            return;
        for (APlayerCharacter Other : NearbyMembers(Earner))
        {
            if (Other.PlayerSkillsComp != nullptr)
                Other.PlayerSkillsComp.WSGrantSharedXP(SkillTag, Share);
        }
    }

    // Harvesting: chance of an extra roll per nearby coven member.
    bool RollCovenBonusHarvest(const APlayerCharacter Player)
    {
        if (!System::IsServer() || !WSCoop::CovenSynergy())
            return false;
        const float Chance = WSCoop::CovenBonusPerMember() * NearbyMembers(Player).Num();
        return Chance > 0 && Math::RandRange(0.0, 1.0) < Chance;
    }
}
