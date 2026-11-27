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
        // Developer test (-WSDevTools -WSDevIdentity=steam_<id>): join as another character.
        if (System::ParseParam(System::GetCommandLine(), "WSDevTools"))
        {
            const FString Forced = WSDS::Param("WSDevIdentity", "");
            if (!Forced.IsEmpty())
                return Forced;
        }
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
    FString ReportedModVersion;
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

    // Luminary respec requests from this player's menus (see WSLuminaryRespec). Kept last and named to sort
    // after the older RPCs, so their network indexes stay the same as in earlier versions.
    UFUNCTION(Server)
    void ServerWSLuminaryRefund(UProgressionComponent Comp, const UProgressionUnlockDefinition Unlock, FGameplayTag PassiveTag)
    {
        WSLuminaryRespec::ServerRefund(Cast<APlayerController>(Owner), Comp, Unlock, PassiveTag);
    }

    UFUNCTION(Server)
    void ServerWSLuminaryReset(UProgressionComponent Comp)
    {
        WSLuminaryRespec::ServerReset(Cast<APlayerController>(Owner), Comp);
    }

    // Map marker requests from this player's world map (see WSMapMarkers). Named to sort after the RPCs above.
    UFUNCTION(Server)
    void ServerWSMapMarker(FVector Location, bool bClear)
    {
        WSMapMarkers::ServerSet(Cast<APlayerController>(Owner), Location, bClear);
    }

    // 0.0.50 and later. Every new RPC is named to sort after the ones above (network indexes of older RPCs stay
    // the same, so games from before the version check still get the "update needed" notice).

    // Map marker with a type (meet, danger, loot, base); RemoveId >= 0 removes that marker of this player instead.
    UFUNCTION(Server)
    void ServerWSMarkerEdit(FVector Location, FString Type, int RemoveId)
    {
        WSMapMarkers::ServerEdit(Cast<APlayerController>(Owner), Location, Type, RemoveId);
    }

    // Quick stack: move items into nearby chests that already hold the same item.
    UFUNCTION(Server)
    void ServerWSQuickStack()
    {
        WSQuickStack::ServerQuickStack(Cast<APlayerController>(Owner));
    }

    // The game's mod version (see WSVersion).
    UFUNCTION(Server)
    void ServerWSVersion(FString Version)
    {
        ReportedModVersion = Version.Left(32);
    }

    // 0.0.53: weapon stat re-roll at the enhancement station (see WSWorkstationExtras). Named to sort after every
    // older RPC of this component.
    UFUNCTION(Server)
    void WSServerWeaponReroll(AItemCraftingWorkstation Station)
    {
        WSWeaponReroll::ServerReroll(Cast<APlayerController>(Owner), Station);
    }

    // 0.0.54: the player's answer to an offered re-roll (keep the current stats or take the new ones). Named to
    // sort after every older RPC of this component.
    UFUNCTION(Server)
    void WSServerWeaponRerollChoice(bool bTakeNew)
    {
        WSWeaponReroll::ServerChoose(Cast<APlayerController>(Owner), bTakeNew);
    }

    // 0.0.54: shows the rolled stats next to the current ones so the player can choose.
    UFUNCTION(Client)
    void WSWeaponRerollOffer(FString Current, FString New)
    {
        UWSWorkstationExtras Extras = UWSWorkstationExtras::Get();
        if (Extras != nullptr)
            Extras.ShowOffer(Current.Left(1000), New.Left(1000));
    }

    // Why the server is about to disconnect this game (shown on the main menu).
    UFUNCTION(Client)
    void WSClientKickReason(FString Reason)
    {
        UWSClientStateSubsystem ClientState = UWSClientStateSubsystem::Get();
        if (ClientState != nullptr && ClientState.VersionProblem.IsEmpty())
            ClientState.KickReason = Reason.Left(300);
    }

    UFUNCTION(Client)
    void WSClientVersionMismatch(FString ServerVersion)
    {
        UWSVersionSubsystem Versions = UWSVersionSubsystem::Get();
        APlayerController PC = Cast<APlayerController>(Owner);
        if (Versions != nullptr && PC != nullptr)
            Versions.LeaveServer(PC, ServerVersion);
    }
};
