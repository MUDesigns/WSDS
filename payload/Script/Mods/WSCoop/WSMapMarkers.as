// WitchspireCoopMod - map markers and teammate compass.
//
// Map markers: every player can mark one spot on the world map (left-click the map; R or the gamepad Reset button
// marks the centre of the view; clicking your own marker removes it). Everyone on the server sees each marker as a
// beam of light in the world (the game's light-beam effect, tinted in the owner's player colour), as an icon on the
// world map, and on the compass at any distance, with the owner's name under it. Markers are kept by the server
// (AWSCoopManager.MapMarkers, saved with the world) and replicated to every game. Setting: Coop.MapMarkers.
//
// Teammate compass: every other player is shown on the compass at any distance with their name under the icon
// (vanilla only shows nearby players, without names), and the world map shows teammates' names under their icons.
// This part is client-side only.

namespace WSMapMarkers
{
    const FString BeamClassPath = "/Game/Art/Marketplace/CartoonWaterShader/EpicGamesFog/Blueprints/BP_LightBeam.BP_LightBeam_C";
    const FString MarkerMapIconPath = "/Game/Art/UI/Icons/Map/T_Icon_map_ping.T_Icon_map_ping";
    const FString TeammateCompassIconPath = "/Game/UserInterface/HUD/Compass/Icons/WBP_CompassIcon_PlayerMarker.WBP_CompassIcon_PlayerMarker_C";
    const FString MarkerCompassIconPath = "/Game/UserInterface/HUD/Compass/Icons/WBP_CompassIcon_Ping.WBP_CompassIcon_Ping_C";
    const FString CompassLabelStylePath = "/Game/UserInterface/Foundation/Text/Styles/Text/TextStyle_S4_Light_Bold.TextStyle_S4_Light_Bold_C";
    const FString MapLabelStylePath = "/Game/UserInterface/Foundation/Text/Styles/Text/TextStyle_S3_Light_Bold.TextStyle_S3_Light_Bold_C";
    const FString ElementPrefix = "WSMarker_";

    // Server setting.
    bool ServerEnabled()
    {
        return WSCoop::Flag("MapMarkers", true);
    }

    UWSMapMarkerView View()
    {
        return UWSMapMarkerView::Get();
    }

    // The compass shows teammates itself (vanilla per-pawn player icons are skipped, see UCompassIconComponent).
    bool ShowsTeammates()
    {
        return !System::IsDedicatedServer() && !WSDS::IsHeadlessHost();
    }

    // Compass icons that ignore the distance fade (markers and teammates are shown at any distance).
    bool IsPinnedIcon(const UCompassIconWidget Icon)
    {
        UWSMapMarkerView V = View();
        return V != nullptr && V.IsPinned(Icon);
    }

    bool IsSaneLocation(const FVector& L)
    {
        // Also rejects NaN (every comparison with NaN is false).
        return Math::Abs(L.X) < 5000000.0 && Math::Abs(L.Y) < 5000000.0 && Math::Abs(L.Z) < 5000000.0;
    }

    // Parses one "key|name|x|y|z" entry.
    bool ParseEntry(const FString& Entry, FString& OutKey, FString& OutName, FVector& OutLocation)
    {
        TArray<FString> F;
        Entry.ParseIntoArray(F, "|", false);
        if (F.Num() != 5)
            return false;
        OutKey = F[0];
        OutName = F[1];
        OutLocation = FVector(String::Conv_StringToDouble(F[2]), String::Conv_StringToDouble(F[3]), String::Conv_StringToDouble(F[4]));
        return true;
    }

    // ---- server ----

    void ServerSet(APlayerController PC, FVector Location, bool bClear)
    {
        if (!System::IsServer() || PC == nullptr)
            return;
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr || !ServerEnabled())
            return;
        APlayerCharacter Player = Cast<APlayerCharacter>(PC.GetControlledPawn());
        if (Player == nullptr)
            return;
        const FString Key = WSCoop::PlayerKey(Player);
        if (Key.IsEmpty())
            return;
        if (bClear)
        {
            if (Manager.ClearMapMarker(Key))
                WSCoop::Info(f"Map marker of {WSCoop::PlayerName(Player)} removed");
            return;
        }
        if (!IsSaneLocation(Location))
            return;
        Manager.SetMapMarker(Key, WSCoop::PlayerName(Player), Location);
        WSCoop::Info(f"Map marker of {WSCoop::PlayerName(Player)} set at {Location}");
    }

    // ---- client ----

    // The local player's own request (from the world map).
    void RequestSet(FVector Location, bool bClear)
    {
        APlayerController PC = Gameplay::GetPlayerController(0);
        if (PC == nullptr)
            return;
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr || !Manager.bMapMarkersEnabled)
        {
            WSCoop::ShowLocalNotice("Map Markers", "This server doesn't support map markers.");
            return;
        }
        if (System::IsServer())
        {
            ServerSet(PC, Location, bClear);
            return;
        }
        UWSIdentityComponent Channel = WSIdentity::GetComponent(PC);
        if (Channel != nullptr)
            Channel.ServerWSMapMarker(Location, bClear);
        else
            WSCoop::ShowLocalNotice("Map Markers", "This server doesn't support map markers.");
    }

    // Ground height at a spot, if that part of the world is loaded here.
    // Visible surfaces under a spot, top to bottom, between Top and Bottom (skips volumes and invisible blockers).
    TArray<FVector> SurfacesBelow(const FVector& Around, float Top, float Bottom)
    {
        TArray<FVector> Out;
        FVector Start = FVector(Around.X, Around.Y, Top);
        const FVector End = FVector(Around.X, Around.Y, Bottom);
        for (int Attempt = 0; Attempt < 48 && Out.Num() < 32; Attempt++)
        {
            FHitResult Hit;
            System::LineTraceSingleByChannel(Hit, Start, End, ECollisionChannel::ECC_Visibility);
            if (!Hit.bBlockingHit)
                break;
            UPrimitiveComponent Comp = Hit.Component;
            AActor HitActor = Hit.Actor;
            const bool bInvisible = Comp == nullptr || !Comp.IsVisible() || (HitActor != nullptr && (HitActor.IsA(AVolume) || HitActor.IsHidden()));
            if (!bInvisible)
                Out.Add(Hit.ImpactPoint);
            Start = Hit.ImpactPoint - FVector(0, 0, 30);
        }
        return Out;
    }

    // Ground just below a stored marker height (markers are saved with the height their owner chose).
    bool FindGround(const FVector& Around, FVector& OutGround)
    {
        TArray<FVector> Surfaces = SurfacesBelow(Around, Around.Z + 1500, Around.Z - 60000);
        if (Surfaces.Num() == 0)
            return false;
        OutGround = Surfaces[0];
        return true;
    }

    // Ground for a spot picked on the map (no height known): near the player, the surface closest to the
    // player's height (under a canopy rather than on top of it); further away, the highest surface.
    bool FindGroundForMapSpot(const FVector& Spot, FVector& OutGround)
    {
        TArray<FVector> Surfaces = SurfacesBelow(Spot, 80000, -80000);
        if (Surfaces.Num() == 0)
            return false;
        OutGround = Surfaces[0];
        APawn Pawn = Game::GetLocalPlayer();
        if (Pawn != nullptr && Pawn.GetActorLocation().Dist2D(Spot) < 40000)
        {
            const float PlayerZ = Pawn.GetActorLocation().Z;
            for (const FVector& S : Surfaces)
            {
                if (Math::Abs(S.Z - PlayerZ) < Math::Abs(OutGround.Z - PlayerZ))
                    OutGround = S;
            }
        }
        if (System::ParseParam(System::GetCommandLine(), "WSMarkerDebug"))
            WSCoop::Info(f"Map markers: {Surfaces.Num()} surfaces under {Spot}, chose {OutGround}");
        return true;
    }

    // Name of the local player (the owner name markers are stored under).
    FString LocalPlayerName()
    {
        APlayerController PC = Gameplay::GetPlayerController(0);
        return (PC != nullptr && PC.PlayerState != nullptr) ? PC.PlayerState.GetPlayerName() : "";
    }

    // Left-click on the world map.
    void OnMapClicked(FVector WorldLocation)
    {
        FVector Target = WorldLocation;
        FVector Ground;
        if (FindGroundForMapSpot(WorldLocation, Ground))
            Target = Ground;
        RequestSet(Target, false);
    }

    // R / gamepad Reset on the world map: mark the centre of the view, or remove your marker if it is already there.
    void OnMapActionPressed(FVector CenterLocation, float ZoomScale)
    {
        UWSMapMarkerView V = View();
        FVector Mine;
        if (V != nullptr && V.GetMarkerOf(LocalPlayerName(), Mine) && Mine.Dist2D(CenterLocation) < 2500.0 * ZoomScale)
        {
            RequestSet(FVector::ZeroVector, true);
            return;
        }
        OnMapClicked(CenterLocation);
    }

    // A click on a map icon. True = it was a marker and has been handled.
    bool OnElementClicked(FName UniqueId)
    {
        const FString Id = UniqueId.ToString();
        if (!Id.StartsWith(ElementPrefix))
            return false;
        UWSMapMarkerView V = View();
        if (V != nullptr && V.IsOwnMarkerElement(UniqueId))
            RequestSet(FVector::ZeroVector, true);
        return true;
    }

    // World map labels: called by UWorldMapWidget.Tick for every element it places.
    void PlaceMapLabel(UOverlay Overlay, const FRegisteredWorldMapElement& Element, FVector2D MapPosition, FVector2D WidgetSize)
    {
        UWSMapMarkerView V = View();
        if (V != nullptr)
            V.PlaceMapLabel(Overlay, Element, MapPosition, WidgetSize);
    }

    void FinishMapLabels(UOverlay Overlay)
    {
        UWSMapMarkerView V = View();
        if (V != nullptr)
            V.FinishMapLabels(Overlay);
    }

    void RegisterMapActions(UWorldMapWidget Widget)
    {
        UWSMapMarkerView V = View();
        if (V == nullptr || Widget == nullptr || V.RegisteredMaps.Contains(Widget))
            return;
        V.RegisteredMaps.Add(Widget);
        UInputAction Action = WSLuminaryRespec::LoadAction(WSLuminaryRespec::ResetActionPath);
        if (Action != nullptr)
            Widget.RegisterUIActionBinding(Action, FSimpleDynamicDelegate(Widget, n"WSOnMarkerAction"));
    }
}

// One marker as this game shows it.
struct FWSMarkerVisual
{
    FString Key;
    FString OwnerName;
    FVector Location;
    bool bGrounded = false;
    AActor Beam;
    UCompassIconWidget Icon;
    FName ElementId;
    bool bSeen = false;
}

// One teammate on the compass.
struct FWSMateVisual
{
    APlayerState State;
    UCompassIconWidget Icon;
    bool bSeen = false;
}

UCLASS()
class UWSMapMarkerView : UScriptWorldSubsystem
{
    private TArray<FWSMarkerVisual> Markers;
    private TArray<FWSMateVisual> Mates;
    private TSet<UCompassIconWidget> PinnedIcons;
    private TMap<UCompassIconWidget, UTextBlock> CompassLabels;
    private TMap<FName, UTextBlock> MapLabels;
    private TSet<FName> MapLabelsSeen;
    TSet<UObject> RegisteredMaps;

    private UClass BeamClass;
    private UClass TeammateIconClass;
    private UClass MarkerIconClass;
    private TSubclassOf<UCommonTextStyle> CompassLabelStyle;
    private TSubclassOf<UCommonTextStyle> MapLabelStyle;
    private UTexture2D MarkerMapIcon;
    private bool bAssetsLoaded = false;
    private bool bServerFlagSet = false;
    private float SyncClock = 0;

    bool IsPinned(const UCompassIconWidget Icon) const
    {
        return Icon != nullptr && PinnedIcons.Contains(Icon);
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        if (System::IsServer() && !bServerFlagSet)
        {
            AWSCoopManager Manager = WSCoop::GetManager();
            if (Manager != nullptr)
            {
                Manager.bMapMarkersEnabled = WSMapMarkers::ServerEnabled();
                bServerFlagSet = true;
            }
        }
        if (!WSMapMarkers::ShowsTeammates())
            return;
        APlayerController PC = Gameplay::GetPlayerController(0);
        UHUDWidget HUD = Game::GetHUDWidget();
        if (PC == nullptr || HUD == nullptr || HUD.Widget_Compass == nullptr || PC.GetControlledPawn() == nullptr)
            return;
        if (!bAssetsLoaded)
            LoadAssets();

        // Teammates move: follow them every frame.
        for (FWSMateVisual& Mate : Mates)
        {
            if (Mate.Icon != nullptr && IsValid(Mate.State))
                Mate.Icon.WSSetTargetLocation(MateLocation(Mate.State));
        }

        SyncClock += DeltaTime;
        if (SyncClock < 0.25)
            return;
        SyncClock = 0;
        SyncMarkers(PC, HUD);
        SyncMates(PC, HUD);
    }

    private void LoadAssets()
    {
        bAssetsLoaded = true;
        BeamClass = Cast<UClass>(LoadObject(UClass, WSMapMarkers::BeamClassPath));
        TeammateIconClass = Cast<UClass>(LoadObject(UClass, WSMapMarkers::TeammateCompassIconPath));
        MarkerIconClass = Cast<UClass>(LoadObject(UClass, WSMapMarkers::MarkerCompassIconPath));
        CompassLabelStyle = Cast<UClass>(LoadObject(UClass, WSMapMarkers::CompassLabelStylePath));
        MapLabelStyle = Cast<UClass>(LoadObject(UClass, WSMapMarkers::MapLabelStylePath));
        MarkerMapIcon = Cast<UTexture2D>(LoadObject(UTexture2D, WSMapMarkers::MarkerMapIconPath));
        WSCoop::Info(f"Map markers: beam {BeamClass != nullptr}, compass icons {TeammateIconClass != nullptr}/{MarkerIconClass != nullptr}, label styles {CompassLabelStyle != nullptr}/{MapLabelStyle != nullptr}, map icon {MarkerMapIcon != nullptr}");
    }

    // ---- colours ----

    // The colour the world map gives this player (by their place in the player list), or a stable colour by name.
    FLinearColor ColorFor(const FString& PlayerName) const
    {
        const TArray<FLinearColor>& Colors = UWorldMapDeveloperSettings::GetPlayerColors();
        if (Colors.Num() == 0)
            return FLinearColor(0.3, 0.9, 1.0, 1);
        AGameStateBase GameState = Gameplay::GetGameState();
        if (GameState != nullptr)
        {
            for (int i = 0; i < GameState.PlayerArray.Num(); i++)
            {
                APlayerState PS = GameState.PlayerArray[i];
                if (PS != nullptr && PS.GetPlayerName() == PlayerName)
                    return Colors[i % Colors.Num()];
            }
        }
        return Colors[Math::Abs(int(PlayerName.GetHash())) % Colors.Num()];
    }

    // ---- markers ----

    bool GetMarkerOf(const FString& OwnerName, FVector& OutLocation) const
    {
        for (const FWSMarkerVisual& M : Markers)
        {
            if (M.OwnerName == OwnerName)
            {
                OutLocation = M.Location;
                return true;
            }
        }
        return false;
    }

    bool IsOwnMarkerElement(FName ElementId) const
    {
        const FString Mine = WSMapMarkers::LocalPlayerName();
        for (const FWSMarkerVisual& M : Markers)
        {
            if (M.ElementId == ElementId)
                return M.OwnerName == Mine;
        }
        return false;
    }

    private void SyncMarkers(APlayerController PC, UHUDWidget HUD)
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        for (FWSMarkerVisual& M : Markers)
            M.bSeen = false;
        if (Manager != nullptr)
        {
            for (const FString& Entry : Manager.MapMarkers)
            {
                FString Key;
                FString OwnerName;
                FVector Location;
                if (!WSMapMarkers::ParseEntry(Entry, Key, OwnerName, Location))
                    continue;
                int Index = -1;
                for (int i = 0; i < Markers.Num(); i++)
                {
                    if (Markers[i].Key == Key)
                    {
                        Index = i;
                        break;
                    }
                }
                if (Index >= 0 && Markers[Index].Location.Dist2D(Location) > 50.0)
                {
                    RemoveMarkerVisual(Markers[Index], HUD);
                    Markers.RemoveAt(Index);
                    Index = -1;
                }
                if (Index < 0)
                {
                    FWSMarkerVisual NewMarker;
                    NewMarker.Key = Key;
                    NewMarker.OwnerName = OwnerName;
                    NewMarker.Location = Location;
                    NewMarker.ElementId = FName(WSMapMarkers::ElementPrefix + Key);
                    Markers.Add(NewMarker);
                    Index = Markers.Num() - 1;
                }
                FWSMarkerVisual& M = Markers[Index];
                M.bSeen = true;
                M.OwnerName = OwnerName;
                UpdateMarkerVisual(M, PC, HUD);
            }
        }
        for (int i = Markers.Num() - 1; i >= 0; i--)
        {
            if (!Markers[i].bSeen)
            {
                RemoveMarkerVisual(Markers[i], HUD);
                Markers.RemoveAt(i);
            }
        }
    }

    private void UpdateMarkerVisual(FWSMarkerVisual& M, APlayerController PC, UHUDWidget HUD)
    {
        const FLinearColor Color = ColorFor(M.OwnerName);

        // Settle the marker on the ground once that part of the world is loaded here.
        if (!M.bGrounded)
        {
            FVector Ground;
            if (WSMapMarkers::FindGround(M.Location, Ground))
            {
                M.Location = Ground;
                M.bGrounded = true;
                if (IsValid(M.Beam))
                    M.Beam.SetActorLocation(Ground);
            }
        }

        if (!IsValid(M.Beam) && BeamClass != nullptr)
            M.Beam = SpawnActor(BeamClass, M.Location, FRotator(90, 0, 0));
        if (IsValid(M.Beam))
            TintBeam(M.Beam, Color);

        if (M.Icon == nullptr && MarkerIconClass != nullptr)
            M.Icon = MakeCompassIcon(MarkerIconClass, M.Location, PC, HUD);
        if (M.Icon != nullptr)
        {
            M.Icon.WSSetTargetLocation(M.Location + FVector(0, 0, 150));
            ColorCompassIcon(M.Icon, Color, true);
            SetCompassLabel(M.Icon, M.OwnerName, PC);
        }

        AWorldMapManager MapManager = AGameManager::Get(AWorldMapManager);
        if (MapManager != nullptr)
        {
            FRegisteredWorldMapElement Element;
            Element.UniqueId = M.ElementId;
            Element.ActorTransform = FTransform(M.Location);
            Element.Info.Generic.UpdateType = EWorldMapElementUpdateType::Static;
            Element.Info.Generic.Name = FText::FromString(f"{M.OwnerName}'s marker");
            const bool bMine = M.OwnerName == WSMapMarkers::LocalPlayerName();
            Element.Info.Generic.Description = FText::FromString(bMine ? "Click to remove your marker." : "A marker placed by a teammate.");
            Element.Info.Generic.Icon = MarkerMapIcon;
            Element.Info.Generic.IconColor = Color;
            Element.Info.Generic.UndiscoveredIcon = MarkerMapIcon;
            Element.Info.Generic.UndiscoveredIconColor = Color;
            Element.Info.Generic.bHideTooltipUntilDiscovered = false;
            Element.Info.Generic.WidgetSize = FVector2D(30, 30);
            Element.Info.Discovery.bIsDiscoverable = false;
            Element.Info.Discovery.CurrentState = EWorldMapElementState::Discovered;
            MapManager.WSSetLocalElement(Element);
        }
    }

    private void RemoveMarkerVisual(FWSMarkerVisual& M, UHUDWidget HUD)
    {
        if (IsValid(M.Beam))
            M.Beam.DestroyActor();
        M.Beam = nullptr;
        RemoveCompassIcon(M.Icon, HUD);
        M.Icon = nullptr;
        AWorldMapManager MapManager = AGameManager::Get(AWorldMapManager);
        if (MapManager != nullptr)
            MapManager.WSRemoveLocalElement(M.ElementId);
    }

    private void TintBeam(AActor Beam, FLinearColor Color)
    {
        for (UActorComponent C : Beam.GetComponentsByClass(UStaticMeshComponent))
        {
            UStaticMeshComponent SM = Cast<UStaticMeshComponent>(C);
            UMaterialInstanceDynamic MID = SM != nullptr ? Cast<UMaterialInstanceDynamic>(SM.GetMaterial(0)) : nullptr;
            if (MID == nullptr)
                continue;
            MID.SetVectorParameterValue(n"Color", Color);
            MID.SetScalarParameterValue(n"Brightness", 14);
            MID.SetScalarParameterValue(n"Width", 420);
            MID.SetScalarParameterValue(n"Length", 30000);
            MID.SetScalarParameterValue(n"FadeDistance", 600);
            SM.SetBoundsScale(100);
            SM.SetCastShadow(false);
        }
    }

    // ---- teammates ----

    FVector MateLocation(APlayerState State) const
    {
        APawn Pawn = State.GetPawn();
        if (Pawn != nullptr)
            return Pawn.GetActorLocation() + FVector(0, 0, 100);
        AHercPlayerState HercState = Cast<AHercPlayerState>(State);
        if (HercState != nullptr)
            return HercState.CurrentTransform.Location + FVector(0, 0, 100);
        return FVector::ZeroVector;
    }

    private void SyncMates(APlayerController PC, UHUDWidget HUD)
    {
        for (FWSMateVisual& Mate : Mates)
            Mate.bSeen = false;
        AGameStateBase GameState = Gameplay::GetGameState();
        if (GameState != nullptr)
        {
            for (APlayerState PS : GameState.PlayerArray)
            {
                if (PS == nullptr || PS == PC.PlayerState || PS.GetPlayerName().IsEmpty() || PS.IsSpectator())
                    continue;
                AHercPlayerState HercState = Cast<AHercPlayerState>(PS);
                if (PS.GetPawn() == nullptr && (HercState == nullptr || HercState.CurrentTransform.Location.IsNearlyZero()))
                    continue;
                int Index = -1;
                for (int i = 0; i < Mates.Num(); i++)
                {
                    if (Mates[i].State == PS)
                    {
                        Index = i;
                        break;
                    }
                }
                if (Index < 0)
                {
                    FWSMateVisual NewMate;
                    NewMate.State = PS;
                    Mates.Add(NewMate);
                    Index = Mates.Num() - 1;
                }
                FWSMateVisual& Mate = Mates[Index];
                Mate.bSeen = true;
                if (Mate.Icon == nullptr && TeammateIconClass != nullptr)
                    Mate.Icon = MakeCompassIcon(TeammateIconClass, MateLocation(PS), PC, HUD);
                if (Mate.Icon != nullptr)
                {
                    Mate.Icon.WSSetTargetLocation(MateLocation(PS));
                    ColorCompassIcon(Mate.Icon, ColorFor(PS.GetPlayerName()), false);
                    SetCompassLabel(Mate.Icon, PS.GetPlayerName(), PC);
                }
            }
        }
        for (int i = Mates.Num() - 1; i >= 0; i--)
        {
            if (!Mates[i].bSeen)
            {
                RemoveCompassIcon(Mates[i].Icon, HUD);
                Mates.RemoveAt(i);
            }
        }
    }

    // ---- compass icons ----

    private UCompassIconWidget MakeCompassIcon(UClass IconClass, FVector Location, APlayerController PC, UHUDWidget HUD)
    {
        UCompassIconWidget Icon = Cast<UCompassIconWidget>(WidgetBlueprint::CreateWidget(IconClass, PC));
        if (Icon == nullptr)
            return nullptr;
        Icon.Initialize(Location);
        PinnedIcons.Add(Icon);
        HUD.Widget_Compass.AddIcon(Icon, 0);

        // Name label under the icon: the icon's own name text if it has one, else a text of ours.
        Icon.SetClipping(EWidgetClipping::Inherit);
        if (!Icon.WSSetLabel("", ""))
        {
            UPanelWidget Panel = nullptr;
            TArray<UWidget> All;
            Icon.GetAllWidgets(All);
            for (UWidget W : All)
            {
                if (Cast<UOverlay>(W) != nullptr)
                {
                    Panel = Cast<UPanelWidget>(W);
                    break;
                }
                if (Panel == nullptr)
                    Panel = Cast<UPanelWidget>(W);
            }
            if (Panel != nullptr)
            {
                UTextBlock Label = NewObject(Icon, UTextBlock);
                if (CompassLabelStyle != nullptr)
                    Label.ApplyStyle(CompassLabelStyle);
                Label.SetShadowOffset(FVector2D(1, 1));
                Label.SetShadowColorAndOpacity(FLinearColor(0, 0, 0, 0.85));
                Label.SetJustification(ETextJustify::Center);
                Label.SetVisibility(ESlateVisibility::HitTestInvisible);
                UPanelSlot LabelSlot = Panel.AddChild(Label);
                UOverlaySlot OverlaySlot = Cast<UOverlaySlot>(LabelSlot);
                if (OverlaySlot != nullptr)
                {
                    OverlaySlot.SetHorizontalAlignment(EHorizontalAlignment::HAlign_Center);
                    OverlaySlot.SetVerticalAlignment(EVerticalAlignment::VAlign_Bottom);
                }
                Label.SetRenderTranslation(FVector2D(0, 24));
                CompassLabels.Add(Icon, Label);
            }
            const FString PanelName = Panel != nullptr ? Panel.GetName().ToString() : "nothing";
            WSCoop::Info(f"Map markers: compass icon {Icon.GetName()} label added to {PanelName}");
        }
        return Icon;
    }

    private void ColorCompassIcon(UCompassIconWidget Icon, FLinearColor Color, bool bMarker)
    {
        TArray<UWidget> All;
        Icon.GetAllWidgets(All);
        for (UWidget W : All)
        {
            UImage Image = Cast<UImage>(W);
            if (Image == nullptr)
                continue;
            const FString WidgetName = W.GetName().ToString();
            if (bMarker && WidgetName == "IconImage")
            {
                if (MarkerMapIcon != nullptr)
                    Image.SetBrushFromTexture(MarkerMapIcon);
                Image.SetColorAndOpacity(Color);
            }
            else if (!bMarker && WidgetName == "Image_Icon")
                Image.SetColorAndOpacity(Color);
        }
    }

    private void SetCompassLabel(UCompassIconWidget Icon, const FString& LabelName, APlayerController PC)
    {
        APawn Pawn = PC.GetControlledPawn();
        const float Meters = Pawn != nullptr ? Pawn.GetActorLocation().Dist2D(Icon.GetTargetLocation()) / 100.0 : 0;
        const FString DistanceText = f"{Meters:.0} m";
        if (Icon.WSSetLabel(LabelName, DistanceText))
            return;
        UTextBlock Label;
        if (CompassLabels.Find(Icon, Label) && Label != nullptr)
            Label.SetText(FText::FromString(f"{LabelName}  {DistanceText}"));
    }

    private void RemoveCompassIcon(UCompassIconWidget Icon, UHUDWidget HUD)
    {
        if (Icon == nullptr)
            return;
        PinnedIcons.Remove(Icon);
        CompassLabels.Remove(Icon);
        if (HUD != nullptr && HUD.Widget_Compass != nullptr)
            HUD.Widget_Compass.RemoveIcon(Icon);
        Icon.RemoveFromParent();
    }

    // ---- world map labels ----

    void PlaceMapLabel(UOverlay Overlay, const FRegisteredWorldMapElement& Element, FVector2D MapPosition, FVector2D WidgetSize)
    {
        FString Text;
        if (Element.Info.Generic.UpdateType == EWorldMapElementUpdateType::Player)
        {
            APlayerController PC = Gameplay::GetPlayerController(0);
            if (Element.PlayerState == nullptr || (PC != nullptr && Element.PlayerState == PC.PlayerState))
                return;
            Text = Element.PlayerState.GetPlayerName();
        }
        else if (Element.UniqueId.ToString().StartsWith(WSMapMarkers::ElementPrefix))
        {
            for (const FWSMarkerVisual& M : Markers)
            {
                if (M.ElementId == Element.UniqueId)
                {
                    Text = M.OwnerName;
                    break;
                }
            }
        }
        if (Text.IsEmpty())
            return;

        UTextBlock Label;
        if (!MapLabels.Find(Element.UniqueId, Label) || !IsValid(Label) || Label.GetParent() != Overlay)
        {
            Label = NewObject(Overlay, UTextBlock);
            if (MapLabelStyle != nullptr)
                Label.ApplyStyle(MapLabelStyle);
            Label.SetShadowOffset(FVector2D(1, 1));
            Label.SetShadowColorAndOpacity(FLinearColor(0, 0, 0, 0.9));
            Label.SetJustification(ETextJustify::Center);
            Label.SetVisibility(ESlateVisibility::HitTestInvisible);
            UOverlaySlot LabelSlot = Overlay.AddChildToOverlay(Label);
            LabelSlot.SetHorizontalAlignment(EHorizontalAlignment::HAlign_Left);
            LabelSlot.SetVerticalAlignment(EVerticalAlignment::VAlign_Top);
            MapLabels.Add(Element.UniqueId, Label);
        }
        Label.SetText(FText::FromString(Text));
        const FVector2D Size = Label.GetDesiredSize();
        Label.SetRenderTranslation(FVector2D(MapPosition.X + WidgetSize.X * 0.5 - Size.X * 0.5, MapPosition.Y + WidgetSize.Y + 2));
        MapLabelsSeen.Add(Element.UniqueId);
    }

    void FinishMapLabels(UOverlay Overlay)
    {
        TArray<FName> Stale;
        for (auto Pair : MapLabels)
        {
            if (!MapLabelsSeen.Contains(Pair.Key))
                Stale.Add(Pair.Key);
        }
        for (FName Id : Stale)
        {
            UTextBlock Label;
            if (MapLabels.Find(Id, Label) && IsValid(Label))
                Label.RemoveFromParent();
            MapLabels.Remove(Id);
        }
        MapLabelsSeen.Empty();
    }
};
