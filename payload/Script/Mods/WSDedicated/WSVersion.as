// WitchspireDedicatedServer - mod version handshake and the player's mod updater.
//
// Every player needs exactly the server's mod version (gameplay scripts must match). The server publishes its
// version (AWSCoopManager.ServerModVersion); each game compares it with its own:
//   * same version: the game reports it (UWSIdentityComponent.ServerWSVersion) and plays on;
//   * different: the game leaves the server by itself and the main menu explains what to do, with an
//     "Update now" button that starts the Co-op Mod updater (WSCoopUpdater.exe, registered as wscoop-update://).
// Games from before this check (0.0.49 and older) never report a version: the server tells them in a notice
// that they need the new mod and disconnects them.
//
// The main menu also asks the updater once per game session whether a new version is out
// (wscoop-update://check: silent unless there is one).

namespace WSVersion
{
    const FString ModVersion = "0.0.54";
    const FString DownloadPage = "https://www.nexusmods.com/witchspire/mods/62";

    // Seconds the server waits for a version report after a player's identity arrived.
    const float ReportTimeout = 20.0;

    FString ModDir()
    {
        return Paths::ConvertRelativePathToFull(f"{Paths::ProjectDir()}../WitchspireCoopMod/");
    }

    bool HasUpdater()
    {
        return Paths::FileExists(f"{ModDir()}WSCoopUpdater.exe");
    }

    // Starts the updater (it shows its own window), or opens the download page when it isn't installed.
    void OpenUpdater(const FString& Mode)
    {
        if (HasUpdater())
        {
            WSDS::Info(f"Version: starting the mod updater ({Mode})");
            System::LaunchURL(f"wscoop-update://{Mode}");
        }
        else
        {
            WSDS::Info("Version: no updater installed - opening the download page");
            System::LaunchURL(DownloadPage);
        }
    }

    // "0.0.50" -> comparable parts.
    TArray<int> Parts(const FString& Version)
    {
        TArray<int> Out;
        TArray<FString> Fields;
        Version.ParseIntoArray(Fields, ".", true);
        for (const FString& F : Fields)
            Out.Add(String::Conv_StringToInt(F));
        while (Out.Num() < 3)
            Out.Add(0);
        return Out;
    }

    // -1 when A is older than B, 0 when equal, 1 when newer.
    int Compare(const FString& A, const FString& B)
    {
        TArray<int> PA = Parts(A);
        TArray<int> PB = Parts(B);
        for (int i = 0; i < Math::Min(PA.Num(), PB.Num()); i++)
        {
            if (PA[i] != PB[i])
                return PA[i] < PB[i] ? -1 : 1;
        }
        return 0;
    }

    // What the player is told after leaving a server with another version. ServerVersion "" = a server from
    // before the version check.
    FString ProblemText(const FString& ServerVersion)
    {
        if (ServerVersion.IsEmpty() || Compare(ServerVersion, ModVersion) < 0)
        {
            const FString Theirs = ServerVersion.IsEmpty() ? "an older version" : f"version {ServerVersion}";
            return f"This server runs {Theirs} of the Witchspire Co-op Mod and you have {ModVersion}. Servers running WSDS update themselves within a few hours - ask the server owner to update, then join again.";
        }
        return f"This server runs Witchspire Co-op Mod {ServerVersion} and you have {ModVersion}. Update the mod, then join again.";
    }

    bool ServerIsNewer(const FString& ServerVersion)
    {
        return !ServerVersion.IsEmpty() && Compare(ServerVersion, ModVersion) > 0;
    }
}

// Server: publishes the version and checks every remote player. Client: compares with the server's version.
UCLASS()
class UWSVersionSubsystem : UScriptWorldSubsystem
{
    // Server side.
    private TMap<APlayerController, float> WaitingSince;
    private TSet<APlayerController> Handled;
    private float Clock = 0;

    // Client side.
    private bool bClientDone = false;
    private float ManagerSeenFor = 0;

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (System::IsServer())
            ServerTick(DeltaTime);
        else
            ClientTick(DeltaTime);
    }

    // ---- server ----

    private void ServerTick(float DeltaTime)
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr)
            return;
        // Developer test (-WSDevTools -WSFakeModVersion=x): pretend to run another version.
        FString Published = WSVersion::ModVersion;
        if (System::ParseParam(System::GetCommandLine(), "WSDevTools"))
            Published = WSDS::Param("WSFakeModVersion", Published);
        if (Manager.ServerModVersion != Published)
            Manager.ServerModVersion = Published;

        Clock += DeltaTime;
        if (Clock < 1.0)
            return;
        Clock = 0;
        const float Now = float(System::GetGameTimeInSeconds());
        for (int i = 0; i < Gameplay::GetNumPlayerControllers(); i++)
        {
            APlayerController PC = Gameplay::GetPlayerController(i);
            if (PC == nullptr || PC.IsLocalController() || Handled.Contains(PC))
                continue;
            UWSIdentityComponent Channel = WSIdentity::GetComponent(PC);
            if (Channel == nullptr)
                continue;
            if (!Channel.ReportedModVersion.IsEmpty())
            {
                Handled.Add(PC);
                if (Channel.ReportedModVersion != Manager.ServerModVersion)
                    Reject(PC, Channel.ReportedModVersion);
                else
                    WSDS::Info(f"Version: '{NameOf(PC)}' runs mod {Channel.ReportedModVersion}");
                continue;
            }
            if (!Channel.bReceived)
                continue;
            float Since = 0;
            if (!WaitingSince.Find(PC, Since))
            {
                WaitingSince.Add(PC, Now);
                continue;
            }
            if (Now - Since >= WSVersion::ReportTimeout)
            {
                Handled.Add(PC);
                RejectOldClient(PC);
            }
        }
    }

    private FString NameOf(APlayerController PC) const
    {
        return PC.PlayerState != nullptr ? PC.PlayerState.GetPlayerName() : "?";
    }

    // A game from before the version check: tell it in a notice (old games show those), then disconnect it.
    private void RejectOldClient(APlayerController PC)
    {
        WSDS::Info(f"Version: '{NameOf(PC)}' runs an older co-op mod (no version report) - disconnecting");
        UWSIdentityComponent Channel = WSIdentity::GetComponent(PC);
        if (Channel != nullptr)
            Channel.ClientCoopMessage(WSCoop::NoticeString("Co-op Mod Update Needed", f"This server runs Witchspire Co-op Mod {WSVersion::ModVersion}. Get the new Witchspire Co-op Mod Setup from Nexus Mods - from then on the mod keeps itself up to date."));
        System::SetTimer(this, n"KickPending", 10.0, false);
        PendingKicks.Add(PC);
    }

    private TArray<APlayerController> PendingKicks;

    UFUNCTION()
    private void KickPending()
    {
        for (APlayerController PC : PendingKicks)
        {
            if (IsValid(PC))
                WSAdmin::Kick(PC, f"This server needs Witchspire Co-op Mod {WSVersion::ModVersion}. Download the new Co-op Mod Setup from Nexus Mods.");
        }
        PendingKicks.Empty();
    }

    // A game with the check but another version (it normally leaves by itself before reporting).
    private void Reject(APlayerController PC, const FString& TheirVersion)
    {
        WSDS::Info(f"Version: '{NameOf(PC)}' runs mod {TheirVersion}, this server {WSVersion::ModVersion} - disconnecting");
        UWSIdentityComponent Channel = WSIdentity::GetComponent(PC);
        if (Channel != nullptr)
            Channel.WSClientVersionMismatch(WSVersion::ModVersion);
        WSAdmin::Kick(PC, f"Mod version mismatch: the server runs {WSVersion::ModVersion}, you have {TheirVersion}.");
    }

    // ---- client ----

    private void ClientTick(float DeltaTime)
    {
        if (bClientDone)
            return;
        APlayerController PC = Gameplay::GetPlayerController(0);
        if (PC == nullptr || !PC.IsLocalController())
            return;
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr)
            return; // not a co-op server (yet)
        if (Manager.ServerModVersion.IsEmpty())
        {
            // A server from before the version check publishes nothing.
            ManagerSeenFor += DeltaTime;
            if (ManagerSeenFor > 15.0)
            {
                bClientDone = true;
                LeaveServer(PC, "");
            }
            return;
        }
        if (Manager.ServerModVersion != WSVersion::ModVersion)
        {
            bClientDone = true;
            LeaveServer(PC, Manager.ServerModVersion);
            return;
        }
        UWSIdentityComponent Channel = WSIdentity::GetComponent(PC);
        if (Channel == nullptr)
            return;
        bClientDone = true;
        // Developer test: behave like a game from before the version check.
        if (System::ParseParam(System::GetCommandLine(), "WSNoVersionReport"))
            return;
        WSDS::Info(f"Version: server and this game both run mod {WSVersion::ModVersion}");
        Channel.ServerWSVersion(WSVersion::ModVersion);
    }

    void LeaveServer(APlayerController PC, const FString& ServerVersion)
    {
        WSDS::Info(f"Version: server runs mod '{ServerVersion}', this game {WSVersion::ModVersion} - leaving");
        UWSClientStateSubsystem ClientState = UWSClientStateSubsystem::Get();
        if (ClientState != nullptr)
        {
            ClientState.VersionProblem = WSVersion::ProblemText(ServerVersion);
            ClientState.bVersionUpdateHelps = WSVersion::ServerIsNewer(ServerVersion);
        }
        PC.ClientReturnToMainMenuWithTextReason(FText::FromString("Mod version mismatch"));
    }
};
