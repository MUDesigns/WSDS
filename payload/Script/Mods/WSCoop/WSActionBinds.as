// WitchspireCoopOverhaul - fewer action-binding messages (fixes "Reliable buffer overflow" kicks on join).
//
// Whenever one action changes (equipping a weapon, a familiar loading or unlocking an ability...), the game's
// UActionComponent re-sends the input binding of all six action slots to the player's game, each as a separate
// reliable network message (UHercAbilityComponent BindInputToAbility / UnbindInputFromAbility). Loading a
// character with many items and familiars does that dozens of times in one frame; past ~256 unacknowledged
// reliable messages on one actor the server closes the connection ("Can't send function
// 'UnbindInputFromAbility' ... Reliable buffer overflow"), so such a player could never join.
//
// On the server this remembers what each player's slots are bound to and only sends real changes. The player's
// game still gets every change (it also rebuilds its bindings from the replicated action list).

struct FWSSlotBinds
{
    TArray<UClass> Bound;
    TArray<bool> Known;
}

namespace WSActionBinds
{
    UWSActionBindCache Cache()
    {
        return UWSActionBindCache::Get();
    }

    void Bind(UHercAbilityComponent Comp, int Slot, FGameplayTag Tag, TSubclassOf<UActionAbility> Ability)
    {
        if (Comp == nullptr)
            return;
        UWSActionBindCache C = Cache();
        if (System::IsServer() && C != nullptr && !C.Changes(Comp, Slot, Ability.Get()))
            return;
        Comp.BindInputToAbility(Tag, Ability);
    }

    void Unbind(UHercAbilityComponent Comp, int Slot, FGameplayTag Tag)
    {
        if (Comp == nullptr)
            return;
        UWSActionBindCache C = Cache();
        if (System::IsServer() && C != nullptr && !C.Changes(Comp, Slot, nullptr))
            return;
        Comp.UnbindInputFromAbility(Tag);
    }
}

UCLASS()
class UWSActionBindCache : UScriptWorldSubsystem
{
    private TMap<UObject, FWSSlotBinds> Slots;
    private float Clock = 0;
    int Sent = 0;
    int Skipped = 0;

    // True when Slot of Comp is not known to be bound to Ability yet (and records it as bound now).
    bool Changes(UHercAbilityComponent Comp, int Slot, UClass Ability)
    {
        if (Slot < 0 || Slot > 31)
            return true;
        FWSSlotBinds Binds;
        Slots.Find(Comp, Binds);
        while (Binds.Bound.Num() <= Slot)
        {
            Binds.Bound.Add(nullptr);
            Binds.Known.Add(false);
        }
        if (Binds.Known[Slot] && Binds.Bound[Slot] == Ability)
        {
            Skipped++;
            return false;
        }
        Binds.Known[Slot] = true;
        Binds.Bound[Slot] = Ability;
        Slots.Add(Comp, Binds);
        Sent++;
        return true;
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (!System::IsServer())
            return;
        Clock += DeltaTime;
        if (Clock < 60.0)
            return;
        Clock = 0;
        // Forget players that left.
        TArray<UObject> Gone;
        for (auto Pair : Slots)
        {
            if (!IsValid(Pair.Key))
                Gone.Add(Pair.Key);
        }
        for (UObject Key : Gone)
            Slots.Remove(Key);
        if (Skipped > 0)
            WSCoop::Info(f"Action bindings: {Sent} sent, {Skipped} repeats skipped");
        Sent = 0;
        Skipped = 0;
    }
};
