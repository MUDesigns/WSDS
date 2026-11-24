// WitchspireDedicatedServer - player identity for direct-IP dedicated servers.
//
// Clients that join a dedicated server with -WSConnect do not log in to EOS (a headless host cannot
// verify EOS ID tokens over a direct-IP link, and logged-in clients refuse to send them unencrypted).
// Without an EOS identity the server cannot tell players apart, so each client reports a stable id:
//   * the SteamID when the game runs under Steam   -> "steam_<steamid64>"
//   * otherwise a random GUID generated once and kept in a local save slot -> "local_<guid>"
// The server turns it into the save-file name. Steam ids map to the exact name vanilla uses
// (the bare SteamID), so characters stay compatible with the normal save layout.
//
// Trust model: this is for private servers among friends. A client could claim someone else's id.

UCLASS()
class UWSIdentitySave : USaveGame
{
    UPROPERTY()
    FString Id;
};

namespace WSIdentity
{
    const FString LocalSlot = "WSIdentity";

    // Client side: the identity this machine reports to dedicated servers.
    FString GetLocalIdentity()
    {
        UWSIdentitySave Save = Cast<UWSIdentitySave>(Gameplay::LoadGameFromSlot(LocalSlot, 0));

        // Running under Steam: use the SteamID and remember it, so sessions started without Steam
        // (JoinServer.bat) map to the same character on the server.
        const FString SteamId = SteamUtil::GetSteamId();
        if (!SteamId.IsEmpty() && SteamId != "0" && SteamId.IsNumeric())
        {
            const FString Id = f"steam_{SteamId}";
            if (Save == nullptr || Save.Id != Id)
            {
                Save = Cast<UWSIdentitySave>(Gameplay::CreateSaveGameObject(UWSIdentitySave));
                Save.Id = Id;
                Gameplay::SaveGameToSlot(Save, LocalSlot, 0);
            }
            return Id;
        }

        if (Save == nullptr || Save.Id.IsEmpty())
        {
            Save = Cast<UWSIdentitySave>(Gameplay::CreateSaveGameObject(UWSIdentitySave));
            Save.Id = f"local_{FGuid::NewGuid().ToString(EGuidFormats::Digits)}";
            Gameplay::SaveGameToSlot(Save, LocalSlot, 0);
        }
        return Save.Id;
    }

    // Server side: convert a reported identity into a safe save name ("" if invalid).
    FString ToSaveName(const FString& Reported)
    {
        if (Reported.StartsWith("steam_"))
        {
            const FString Digits = Reported.RightChop(6);
            if (Digits.Len() >= 5 && Digits.Len() <= 20 && Digits.IsNumeric())
                return Digits;
            return "";
        }
        if (Reported.StartsWith("local_") && Reported.Len() <= 64)
        {
            // Never use client text directly in a file name: hash it.
            return f"ws_{Reported.GetHash()}";
        }
        return "";
    }

    // Server: attach the identity component to an anonymous player's controller.
    // Server: attach the per-player coop channel (identity reports + coop notices) to remote players.
    void Attach(APlayerController PC)
    {
        if (!System::IsServer() || PC == nullptr || PC.IsLocalController())
            return;
        UWSIdentityComponent::GetOrCreate(PC);
        if (IsAnonymous(PC))
            WSDS::Info(f"Anonymous player '{PC.PlayerState.GetPlayerName()}' joined; requesting identity");
    }

    UWSIdentityComponent GetComponent(const APlayerController PC)
    {
        if (PC == nullptr)
            return nullptr;
        return Cast<UWSIdentityComponent>(PC.GetComponentByClass(UWSIdentityComponent));
    }

    // Server side: save name for a player that joined without an online identity, "" if none (yet).
    FString GetSaveName(const APlayerController PC)
    {
        UWSIdentityComponent Comp = GetComponent(PC);
        return Comp != nullptr ? Comp.SaveName : "";
    }

    // True when the player connected without an EOS identity (direct-IP dedicated-server client).
    bool IsAnonymous(const APlayerController PC)
    {
        if (PC == nullptr || PC.PlayerState == nullptr || PC.IsLocalController())
            return false;
        const FString NetId = PC.PlayerState.GetUniqueId().ToString();
        return NetId.IsEmpty() || NetId == "INVALID" || NetId == "None";
    }
}

// Attached at runtime by the server (AHercGameMode.OnPostLogin) to anonymous players' controllers only.
// Never add it as a DefaultComponent: BP_PlayerController is a cooked Blueprint child of
// AHercPlayerController and changing the parent's component layout breaks its serialization.
UCLASS()
class UWSIdentityComponent : UHercActorComponent
{
    default bReplicates = true;

    // Server-side only.
    FString SaveName;
    FString ReportedPassword;
    bool bReceived = false;
    float WaitedSeconds = 0;

    UFUNCTION(BlueprintOverride)
    void BeginPlay()
    {
        APlayerController PC = Cast<APlayerController>(Owner);
        if (PC == nullptr || !PC.IsLocalController() || System::IsServer())
            return;
        // Only players without an online identity need to report one.
        if (PC.PlayerState != nullptr && !PC.PlayerState.GetUniqueId().ToString().IsEmpty() && PC.PlayerState.GetUniqueId().ToString() != "INVALID")
            return;

        const FString Id = WSIdentity::GetLocalIdentity();
        // Server password: typed in the Join dialog, or -WSPassword for JoinServer.bat.
        FString ServerPassword = WSDS::Param("WSPassword", "");
        UWSClientStateSubsystem ClientState = UWSClientStateSubsystem::Get();
        if (ClientState != nullptr && !ClientState.ServerPassword.IsEmpty())
            ServerPassword = ClientState.ServerPassword;
        WSDS::Info(f"Client: reporting identity '{Id}' to server");
        ServerReportIdentity(Id, ServerPassword);
    }

    UFUNCTION(Server)
    void ServerReportIdentity(FString Reported, FString Password)
    {
        ReportedPassword = Password.Left(128);
        if (bReceived)
            return; // fixed for the lifetime of the connection

        const FString CleanName = WSIdentity::ToSaveName(Reported);
        if (CleanName.IsEmpty())
        {
            WSDS::Info(f"Rejected malformed identity report '{Reported.Left(80)}'");
            return;
        }
        SaveName = CleanName;
        bReceived = true;
        APlayerController PC = Cast<APlayerController>(Owner);
        const FString PlayerName = (PC != nullptr && PC.PlayerState != nullptr) ? PC.PlayerState.GetPlayerName() : "?";
        WSDS::Info(f"Identity for '{PlayerName}': save name '{SaveName}'");
    }

    // Coop notice shown only to this player.
    UFUNCTION(Client)
    void ClientCoopMessage(const FString& Message)
    {
        WSCoop::ShowLocalMessage(FText::FromString(Message));
    }

    // Per-player loot, shown only on this player's screen (see UWSCoopLootView).
    UFUNCTION(Client)
    void ClientLootGathered(AHarvestableActor Node, const FString& Key, float Seconds)
    {
        UWSCoopLootView View = UWSCoopLootView::Get();
        if (View != nullptr)
            View.LocalGathered(Node, Key, Seconds);
    }

    UFUNCTION(Client)
    void ClientLootChestOpened(AWorldLootChestActor Chest, const FString& Key)
    {
        UWSCoopLootView View = UWSCoopLootView::Get();
        if (View != nullptr)
            View.LocalChestOpened(Chest, Key);
    }

    UFUNCTION(Client)
    void ClientLootSync(const TArray<FString>& Names, const TArray<float>& Seconds)
    {
        UWSCoopLootView View = UWSCoopLootView::Get();
        if (View != nullptr)
            View.LocalSync(Names, Seconds);
    }

    UFUNCTION(Client)
    void ClientLootUnhide(const FString& Key)
    {
        UWSCoopLootView View = UWSCoopLootView::Get();
        if (View != nullptr)
            View.LocalUnhide(Key);
    }
};
