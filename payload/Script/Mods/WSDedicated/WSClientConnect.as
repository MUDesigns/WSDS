// WitchspireDedicatedServer - client direct connect.
// Launch the game with -WSConnect=<host>[:port] to join a dedicated server by IP.
// Skips EOS login (see MainMenuWidget patch) and identifies via WSIdentity instead.

UCLASS()
class UWSClientConnectSubsystem : UScriptWorldSubsystem
{
    private FString Target;
    private bool bDone = false;
    private float Accumulator = 0;
    private float Waited = 0;

    UFUNCTION(BlueprintOverride)
    void OnWorldBeginPlay()
    {
        if (WSDS::IsHeadlessHost())
            return;
        if (!GetWorld().GetName().ToString().Contains("FrontEnd"))
            return;

        Target = WSDS::Param("WSConnect", "");
        if (Target.IsEmpty())
            return;

        // Only auto-connect once per process; returning to the menu later should not re-join.
        if (UWSClientStateSubsystem::Get().bAutoConnectUsed)
        {
            Target = "";
            return;
        }
        WSDS::Info(f"Client: auto-connect target '{Target}'");
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (Target.IsEmpty() || bDone)
            return;

        Accumulator += DeltaTime;
        if (Accumulator < 0.5)
            return;
        Waited += Accumulator;
        Accumulator = 0;

        // The main menu skips EOS login in -WSConnect mode (see MainMenuWidget), so just give the
        // front end a moment to settle and connect.
        if (Waited < 1.5)
            return;

        bDone = true;
        UWSClientStateSubsystem::Get().bAutoConnectUsed = true;
        // Player name travels in the URL (UE uses the Name option for PlayerState.PlayerName, max 20 chars).
        FString PlayerName = WSDS::Param("WSName", "").Replace("?", "").Replace("=", "").Replace(" ", "_").Left(20);
        FString Url = Target;
        if (!PlayerName.IsEmpty())
            Url = f"{Target}?Name={PlayerName}";
        WSDS::Info(f"Client: connecting to {Url} (direct IP, no EOS login)");
        System::ExecuteConsoleCommand(f"open {Url}");
    }
};

// Survives map travel (game instance lifetime) so auto-connect happens once per process.
UCLASS()
class UWSClientStateSubsystem : UScriptGameInstanceSubsystem
{
    bool bAutoConnectUsed = false;

    // Set when the Join Dedicated Server dialog signed out of EOS; the main menu signs back in.
    bool bSignedOutForDedicated = false;

    // Password typed in the Join Dedicated Server dialog (sent with the identity report).
    FString ServerPassword;
};
