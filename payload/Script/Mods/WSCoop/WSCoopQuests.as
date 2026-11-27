// WitchspireCoopOverhaul - shared quest / spire / milestone progression.
//
// * Every completed objective is recorded in the world (AWSCoopManager.WorldCompletedObjectives).
// * SharedObjectives: when any player completes an objective, it is completed for every other
//   connected player too, including its per-player completion effects (unlock gameplay effects, which
//   is how story steps grant abilities such as broom flight).
// * RetroactiveMilestones: when a player's objectives finish loading, every world-recorded objective
//   they are missing is completed for them (in original completion order), so late joiners are never
//   soft-locked out of regions, flight or story steps.
// * World-level effects (key items, corruption events, global narration) run once per world: only on
//   the very first completion of an objective, never on propagated / retroactive completions.

namespace WSCoopQuests
{
    // Transient context while an objective's effects are executing (effects run synchronously).
    FGameplayTag GetCurrentTag()
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        return Manager != nullptr ? Manager.CurrentCompletionTag : FGameplayTag();
    }

    void BeginCompletion(FGameplayTag Tag)
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager != nullptr)
            Manager.CurrentCompletionTag = Tag;
    }

    void EndCompletion()
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager != nullptr)
            Manager.CurrentCompletionTag = FGameplayTag();
    }

    // For world-level effects: true only for the first completion of the current objective in this world.
    bool IsFirstWorldCompletion()
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr)
            return true;
        if (Manager.bPropagating)
            return false;
        const FGameplayTag Tag = Manager.CurrentCompletionTag;
        if (!Tag.IsValid())
            return true;
        return !Manager.WorldCompletedObjectives.Contains(Tag);
    }

    // Called (server) at the end of UObjectiveComponent::CompleteObjective for live completions.
    void OnObjectiveCompleted(APlayerCharacter Finisher, FGameplayTag Tag, bool bIsGlobal)
    {
        if (!System::IsServer() || !Tag.IsValid())
            return;
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr)
            return;

        const bool bNew = !Manager.WorldCompletedObjectives.Contains(Tag);
        Manager.AddWorldObjective(Tag);
        if (Finisher != nullptr)
            Manager.MarkEffectsApplied(Tag, WSCoop::PlayerKey(Finisher));

        if (Manager.bPropagating || !WSCoop::SharedObjectives())
            return;

        if (bNew)
            WSCoop::Info(f"Objective {Tag} completed by {WSCoop::PlayerName(Finisher)} - sharing with the coven");

        Manager.bPropagating = true;
        for (APlayerCharacter Other : WSCoop::GetPlayers())
        {
            if (Other == Finisher)
                continue;
            GrantObjective(Manager, Other, Tag, bIsGlobal, "shared");
        }
        Manager.bPropagating = false;
    }

    // Completes Tag for Player (non-global) or applies its missing effects (global). Returns true if anything changed.
    bool GrantObjective(AWSCoopManager Manager, APlayerCharacter Player, FGameplayTag Tag, bool bIsGlobal, const FString& Reason)
    {
        if (Player == nullptr || Player.ObjectiveComp == nullptr)
            return false;
        const FString Key = WSCoop::PlayerKey(Player);

        if (!Player.ObjectiveComp.IsObjectiveComplete(Tag))
        {
            Player.ObjectiveComp.ForceComplete(Tag, false);
            Manager.MarkEffectsApplied(Tag, Key);
            WSCoop::Info(f"  {Reason}: completed {Tag} for {WSCoop::PlayerName(Player)}");
            return true;
        }

        // Already complete (global objectives sync without effects): run the effects once per player.
        if (bIsGlobal && !Manager.HasEffectsApplied(Tag, Key))
        {
            Player.ObjectiveComp.WSApplyCompletionEffects(Tag);
            Manager.MarkEffectsApplied(Tag, Key);
            WSCoop::Info(f"  {Reason}: applied effects of global {Tag} for {WSCoop::PlayerName(Player)}");
            return true;
        }
        return false;
    }

    // Called (server) when a player's objectives have finished loading.
    void CatchUp(APlayerCharacter Player)
    {
        if (!System::IsServer() || Player == nullptr || !WSCoop::RetroactiveMilestones())
            return;
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr || Manager.bPropagating || Manager.WorldCompletedObjectives.Num() == 0)
            return;

        // Wait until the player's character save has been applied; granting before that would be
        // overwritten by the load (and could apply one-off effects twice).
        APlayerController PC = Cast<APlayerController>(Player.Controller);
        USaveSubsystem SaveSubsystem = USaveSubsystem::Get();
        if (SaveSubsystem != nullptr && SaveSubsystem.IsEnabled() && !Manager.IsPlayerLoaded(PC))
            return;

        int Granted = 0;
        Manager.bPropagating = true;
        // Copy: completions may append to the list while we iterate.
        TArray<FGameplayTag> Tags = Manager.WorldCompletedObjectives;
        for (FGameplayTag Tag : Tags)
        {
            UObjective Objective = Player.ObjectiveComp.GetObjectiveByTag(Tag);
            if (Objective == nullptr)
                continue;
            if (GrantObjective(Manager, Player, Tag, Objective.bIsGlobal, "catch-up"))
                Granted++;
        }
        Manager.bPropagating = false;

        if (Granted > 0)
        {
            WSCoop::Info(f"Catch-up: {WSCoop::PlayerName(Player)} received {Granted} world milestone(s)");
            WSCoop::Notify(Player, f"{Granted} milestone(s) already achieved in this world.", "Coven Progress Synced");
        }
    }
}
