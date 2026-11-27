// WitchspireCoopOverhaul - sleep through the night.
//
// At night (20:00 to 6:00), pressing interact on a bed also lies the player down to sleep (it still sets their
// spawn point, see WSBedSpawn). A player stays asleep while they stay by the bed. When every living player online
// is asleep, the night is skipped to the morning: everyone's screen fades out and back in, and the clock jumps to
// 7:00. Setting: Coop.SleepThroughNight (default true).

namespace WSSleep
{
    const float NightStart = 20.0;
    const float NightEnd = 6.0;
    const float MorningHour = 7.0;
    const float StayRadius = 250.0;

    bool Enabled() { return WSCoop::Flag("SleepThroughNight", true); }

    // Hour of the day (0-24), -1 if the day cycle isn't available.
    float Hour()
    {
        UDaySequenceSubsystem DaySequence = UDaySequenceSubsystem::Get();
        ADaySequenceActor Actor = DaySequence != nullptr ? DaySequence.GetDaySequenceActor(false) : nullptr;
        return Actor != nullptr ? Actor.GetTimeOfDay() : -1.0;
    }

    bool IsNight()
    {
        const float H = Hour();
        return H >= 0 && (H >= NightStart || H < NightEnd);
    }

    FString HourText(float H)
    {
        const int Whole = Math::FloorToInt(H);
        const int Minutes = int((H - Whole) * 60.0);
        return f"{Whole:02}:{Minutes:02}";
    }

    // Server, from the bed interaction. True when the player lay down to sleep.
    bool TryToSleep(APlayerCharacter Player, AWSBedMarker Marker)
    {
        if (!System::IsServer() || Player == nullptr || !Enabled())
            return false;
        if (!IsNight())
            return false;
        UWSSleepSubsystem Sleep = UWSSleepSubsystem::Get();
        if (Sleep == nullptr)
            return false;
        Sleep.Lie(Player);
        return true;
    }

    // Every game: the night was skipped (AWSCoopManager.NightSkips changed).
    void OnNightSkippedLocal()
    {
        UWSSleepSubsystem Sleep = UWSSleepSubsystem::Get();
        if (Sleep != nullptr)
            Sleep.FadeLocalScreen();
    }
}

UCLASS()
class UWSSleepSubsystem : UScriptWorldSubsystem
{
    // Server: sleeping players and where they lay down.
    private TMap<APlayerCharacter, FVector> Sleepers;
    private float Clock = 0;

    void Lie(APlayerCharacter Player)
    {
        const bool bAlready = Sleepers.Contains(Player);
        Sleepers.Add(Player, Player.GetActorLocation());
        const int Needed = Awake().Num() + Sleepers.Num();
        WSCoop::Info(f"Sleep: {WSCoop::PlayerName(Player)} lies down ({Sleepers.Num()}/{Needed})");
        if (!bAlready && Sleepers.Num() < Needed)
        {
            for (APlayerCharacter P : WSCoop::GetPlayers())
            {
                if (P == Player)
                    WSCoop::Notify(P, f"You are sleeping ({Sleepers.Num()} of {Needed}). The night is skipped once everyone is asleep. Move away to get up.", "Sleeping");
                else
                    WSCoop::Notify(P, f"{WSCoop::PlayerName(Player)} is sleeping ({Sleepers.Num()} of {Needed}). Sleep in a bed to skip the night.", "Sleeping");
            }
        }
        Check();
    }

    // Living players who are not asleep.
    private TArray<APlayerCharacter> Awake() const
    {
        TArray<APlayerCharacter> Out;
        for (APlayerCharacter P : WSCoop::GetPlayers())
        {
            if (P.IsAlive() && !Sleepers.Contains(P))
                Out.Add(P);
        }
        return Out;
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (!System::IsServer() || Sleepers.Num() == 0)
            return;
        Clock += DeltaTime;
        if (Clock < 0.5)
            return;
        Clock = 0;
        // Getting up: moving away from the bed, dying, leaving, or the night ending on its own.
        TArray<APlayerCharacter> Up;
        const bool bNight = WSSleep::IsNight();
        for (auto Pair : Sleepers)
        {
            if (!IsValid(Pair.Key) || !Pair.Key.IsAlive() || !bNight || Pair.Key.GetActorLocation().Distance(Pair.Value) > WSSleep::StayRadius)
                Up.Add(Pair.Key);
        }
        for (APlayerCharacter P : Up)
        {
            Sleepers.Remove(P);
            if (IsValid(P))
                WSCoop::Info(f"Sleep: {WSCoop::PlayerName(P)} got up");
        }
        Check();
    }

    private void Check()
    {
        if (Sleepers.Num() == 0 || Awake().Num() > 0 || !WSSleep::IsNight())
            return;
        SkipNight();
    }

    private void SkipNight()
    {
        const float From = WSSleep::Hour();
        UWSAdminSubsystem Admin = UWSAdminSubsystem::Get();
        if (Admin == nullptr || !Admin.SetTimeOfDay(WSSleep::MorningHour))
        {
            WSCoop::Info("Sleep: could not change the time of day");
            return;
        }
        WSCoop::Info(f"Sleep: everyone is asleep - night skipped from {WSSleep::HourText(From)} to {WSSleep::HourText(WSSleep::MorningHour)}");
        Sleepers.Empty();
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager != nullptr)
        {
            Manager.NightSkips++;
            if (!WSDS::IsHeadlessHost())
                FadeLocalScreen(); // a listen host doesn't get its own replication callback
        }
        for (APlayerCharacter P : WSCoop::GetPlayers())
            WSCoop::Notify(P, "Everyone slept through the night.", "Good Morning");
    }

    // ---- every game ----

    void FadeLocalScreen()
    {
        if (WSDS::IsHeadlessHost())
            return;
        APlayerCameraManager Camera = Gameplay::GetPlayerCameraManager(0);
        if (Camera == nullptr)
            return;
        Camera.StartCameraFade(0.0, 1.0, 0.6, FLinearColor::Black, false, true);
        System::SetTimer(this, n"FadeBackIn", 1.4, false);
    }

    UFUNCTION()
    private void FadeBackIn()
    {
        APlayerCameraManager Camera = Gameplay::GetPlayerCameraManager(0);
        if (Camera != nullptr)
            Camera.StartCameraFade(1.0, 0.0, 1.2, FLinearColor::Black, false, false);
    }

    bool IsSleeping(APlayerCharacter Player) const
    {
        return Sleepers.Contains(Player);
    }

    // Tests.
    int NumSleepers() const
    {
        return Sleepers.Num();
    }
};
