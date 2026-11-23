// WitchspireCoopOverhaul - sanctuary / base co-ownership.
//
// Vanilla Witchspire has no ownership model: every player can use and modify every hearth, chest,
// workstation and building (only one player can have a chest/station UI open at a time).
// CoOwnerPermissions (ServerConfig.json -> Coop):
//   "AllPlayers"  (default) every connected player is a full co-owner of all sanctuaries.
//   "AdminsOnly"  only players listed in "Admins" (comma separated names or save ids) may place or
//                 destroy buildings and level up hearths. Everyone can still use chests and stations.

namespace WSCoopPermissions
{
    bool CanModifySanctuary(const APlayerCharacter Player)
    {
        const FString Mode = WSCoop::Raw("CoOwnerPermissions");
        if (Mode.IsEmpty() || Mode == "AllPlayers")
            return true;
        if (Player == nullptr)
            return false;

        APlayerController PC = Cast<APlayerController>(Player.Controller);
        if (PC != nullptr && PC.IsLocalController())
            return true; // the host's own character (listen servers)

        TArray<FString> Admins;
        WSCoop::Raw("Admins").ParseIntoArray(Admins, ",", true);
        const FString Name = WSCoop::PlayerName(Player);
        const FString Key = WSCoop::PlayerKey(Player);
        for (const FString& Entry : Admins)
        {
            const FString Admin = Entry.TrimStartAndEnd();
            if (Admin == Name || Admin == Key)
                return true;
        }
        return false;
    }

    // Server-side gate with feedback; returns false when the action must be refused.
    bool Check(const APlayerCharacter Player, const FString& Action)
    {
        if (!System::IsServer() || CanModifySanctuary(Player))
            return true;
        WSCoop::Info(f"Permission denied: {WSCoop::PlayerName(Player)} tried to {Action}");
        WSCoop::Notify(Player, f"Only server admins can {Action} on this server.");
        return false;
    }
}
