// WitchspireDedicatedServer - developer tools that produce the static data for wsdsmaps.com.
//
// Server: admin command `mapsurvey <stepCm>` walks the host's viewpoint over the island so every part of the
// world streams in once, and logs each chest, satchel and landmark:
//     [WSDS-CATALOG] <kind>|<actorName>|<x>|<y>|<z>|<className>|<displayName>
// Client: started with -WSExportMap=<dir>, a rendering game writes the world map texture to <dir>/worldmap.png
// and logs the map bounds:
//     [WSDS-MAPINFO] {"upperLeft":[x,y],"levelSize":[w,h],"texture":[W,H]}

UCLASS()
class UWSMapSurveySubsystem : UScriptWorldSubsystem
{
    private bool bRunning = false;
    private TArray<FVector> Points;
    private int PointIndex = 0;
    private float PointTime = 0;
    private float CheckTime = 0;
    private int LastCount = -1;
    private int StableChecks = 0;
    private TSet<FString> Seen;
    private int Found = 0;
    private ATeleportPreloadBeacon Beacon;

    // Export (client)
    private FString ExportDir;
    private float ExportDelay = -1;

    UFUNCTION(BlueprintOverride)
    void OnWorldBeginPlay()
    {
        ExportDir = WSDS::Param("WSExportMap", "");
    }

    void Start(float InStepCm, const TArray<float>& Area)
    {
        const float StepCm = Math::Clamp(InStepCm, 5000.0, 200000.0); // 0 or junk would never finish
        TArray<AWorldMap> Maps;
        GetAllActorsOfClass(Maps);
        if (Maps.Num() == 0)
        {
            WSAdmin::Result(false, "mapsurvey", "no world map actor");
            return;
        }
        AWorldMap Map = Maps[0];
        // Survey only where the landmarks are (plus a margin): the rest of the map square is sea.
        FVector Min = FVector(1e12, 1e12, 0);
        FVector Max = FVector(-1e12, -1e12, 0);
        for (const FStaticWorldMapElement& Element : Map.StaticMapElements)
        {
            const FVector L = Element.ActorTransform.GetLocation();
            Min = FVector(Math::Min(Min.X, L.X), Math::Min(Min.Y, L.Y), 0);
            Max = FVector(Math::Max(Max.X, L.X), Math::Max(Max.Y, L.Y), 0);
            LogCatalog("landmark", Element.UniqueId.ToString(), L, "StaticMapElement", Element.Info.Generic.Name.ToString());
        }
        const float Margin = 40000;
        Min -= FVector(Margin, Margin, 0);
        Max += FVector(Margin, Margin, 0);
        Min = FVector(Math::Max(Min.X, Map.UpperLeftBound.X), Math::Max(Min.Y, Map.UpperLeftBound.Y), 0);
        Max = FVector(Math::Min(Max.X, Map.UpperLeftBound.X + Map.LevelSize.X), Math::Min(Max.Y, Map.UpperLeftBound.Y + Map.LevelSize.Y), 0);
        if (Area.Num() == 4)
        {
            Min = FVector(Area[0], Area[1], 0);
            Max = FVector(Area[2], Area[3], 0);
        }
        // The islands float at very different heights (and portals lead to areas far below), and the world
        // streams in 3D: every point takes the height of the nearest landmark, and each landmark also gets a
        // small cluster of points at its own height.
        TArray<FVector> Landmarks;
        for (const FStaticWorldMapElement& Element : Map.StaticMapElements)
            Landmarks.Add(Element.ActorTransform.GetLocation());
        Points.Empty();
        int Row = 0;
        for (float Y = Min.Y; Y <= Max.Y; Y += StepCm)
        {
            // Serpentine: every other row runs backwards so the viewpoint never jumps across the island.
            TArray<FVector> RowPoints;
            for (float X = Min.X; X <= Max.X; X += StepCm)
            {
                float Best = 150000;
                float Z = 0;
                bool bNear = false;
                for (const FVector& L : Landmarks)
                {
                    const float D = float(FVector(X, Y, 0).Dist2D(L));
                    if (D < Best && L.Z > -100000)
                    {
                        Best = D;
                        Z = float(L.Z);
                        bNear = true;
                    }
                }
                if (bNear)
                    RowPoints.Add(FVector(X, Y, Z));
            }
            for (int i = 0; i < RowPoints.Num(); i++)
                Points.Add(RowPoints[Row % 2 == 1 ? RowPoints.Num() - 1 - i : i]);
            Row++;
        }
        for (const FVector& L : Landmarks)
        {
            if (Area.Num() == 4)
                break; // an explicit area is surveyed on its own
            for (int dx = -1; dx <= 1; dx++)
            {
                for (int dy = -1; dy <= 1; dy++)
                {
                    const FVector P = L + FVector(dx * StepCm, dy * StepCm, 0);
                    bool bClose = false;
                    for (const FVector& Q : Points)
                    {
                        if (Q.Distance(P) < StepCm * 0.5)
                        {
                            bClose = true;
                            break;
                        }
                    }
                    if (!bClose)
                        Points.Add(P);
                }
            }
        }
        PointIndex = -1;
        bRunning = true;
        WSDS::Info(f"mapsurvey: {Points.Num()} points, step {int(StepCm)} cm, area {int(Min.X)},{int(Min.Y)} .. {int(Max.X)},{int(Max.Y)}");
        NextPoint();
    }

    private void NextPoint()
    {
        PointIndex++;
        if (PointIndex >= Points.Num())
        {
            bRunning = false;
            if (Beacon != nullptr)
                Beacon.DestroyActor();
            Beacon = nullptr;
            WSAdmin::Result(true, "mapsurvey", f"{Found} actors");
            return;
        }
        // A headless host's own viewpoint does not stream the world; the game's teleport preload beacon does.
        if (Beacon == nullptr)
            Beacon = Cast<ATeleportPreloadBeacon>(SpawnActor(ATeleportPreloadBeacon, Points[PointIndex], FRotator::ZeroRotator));
        else
            Beacon.SetActorLocation(Points[PointIndex]);
        PointTime = 0;
        CheckTime = 0;
        LastCount = -1;
        StableChecks = 0;
        if (PointIndex % 25 == 0)
            WSDS::Info(f"mapsurvey: point {PointIndex}/{Points.Num()}, {Found} actors so far, beacon={Beacon != nullptr} at {Beacon != nullptr ? Beacon.GetActorLocation() : FVector::ZeroVector} streaming={Beacon != nullptr && Beacon.StreamingSourceComp.IsStreamingSourceEnabled()}");
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        // Export starts once this (client) world has a player character, then waits a little for streaming.
        if (!bExportChecked)
        {
            bExportChecked = true;
            ExportDir = WSDS::Param("WSExportMap", "");
            ClientSurveyStep = float(WSDS::IntParam("WSSurvey", 0));
        }
        // Client-side survey (-WSSurvey=<stepCm>): a game client streams the world around any streaming source,
        // a headless server only around players.
        if (ClientSurveyStep > 0 && !System::IsServer() && !bRunning && PointIndex == 0 && Points.Num() == 0)
        {
            ClientSurveyWait += DeltaTime;
            if (Gameplay::GetPlayerPawn(0) != nullptr && ClientSurveyWait > 15.0)
            {
                TArray<float> NoArea;
                Start(ClientSurveyStep, NoArea);
            }
        }
        if (!ExportDir.IsEmpty() && !System::IsServer() && ExportDelay < 0 && ExportAttempts == 0 && Tiles.Num() == 0)
        {
            ExportWait += DeltaTime;
            if (Gameplay::GetPlayerPawn(0) != nullptr)
                ExportDelay = 10.0;
            else if (ExportWait > 10.0)
            {
                ExportWait = 0;
                Log(n"WSDS", f"[WSDS-EXPORT] waiting for a player character in {GetWorld().GetName()}");
            }
        }
        if (ExportDelay > 0)
        {
            ExportDelay -= DeltaTime;
            if (ExportDelay <= 0)
                ExportMap();
        }
        if (ExportAfterLoad > 0)
        {
            ExportAfterLoad -= DeltaTime;
            if (ExportAfterLoad <= 0)
                ExportTiles();
        }
        if (!bRunning)
            return;
        PointTime += DeltaTime;
        CheckTime += DeltaTime;
        if (CheckTime < 0.5)
            return;
        CheckTime = 0;
        const int Count = Collect();
        StableChecks = (Count == LastCount) ? StableChecks + 1 : 0;
        LastCount = Count;
        // Move on once the game reports this spot fully loaded and the loaded set has settled (max 25 s).
        const bool bReady = PointTime >= 1.0 && Loading::CheckPartition(this, Points[PointIndex]);
        if ((bReady && StableChecks >= 2) || PointTime >= 25.0)
        {
            Log(n"WSDS", f"[WSDS-SURVEYPT] {PointIndex} loaded={Count} maxDist={int(MaxDist)} t={PointTime:.1}");
            NextPoint();
        }
    }

    // Logs every not-yet-seen chest / satchel currently loaded; returns how many are loaded.
    private float MaxDist = 0;

    private int Collect()
    {
        int Loaded = 0;
        MaxDist = 0;
        TArray<AWorldChestActor> Chests;
        GetAllActorsOfClass(Chests);
        for (AWorldChestActor A : Chests)
        {
            Loaded++;
            Note("chest", A);
        }
        TArray<AWorldLootChestActor> LootChests;
        GetAllActorsOfClass(LootChests);
        for (AWorldLootChestActor A : LootChests)
        {
            Loaded++;
            Note("chest", A);
        }
        TArray<AHarvestableActor> Harvestables;
        GetAllActorsOfClass(Harvestables);
        for (AHarvestableActor A : Harvestables)
        {
            if (!A.Class.GetName().ToString().Contains("Satchel"))
                continue;
            Loaded++;
            Note("satchel", A);
        }
        return Loaded;
    }

    private void Note(const FString& Kind, AActor A)
    {
        if (Points.IsValidIndex(PointIndex))
            MaxDist = Math::Max(MaxDist, float(A.GetActorLocation().Dist2D(Points[PointIndex])));
        const FString ActorName = A.GetName().ToString();
        if (Seen.Contains(ActorName))
            return;
        Seen.Add(ActorName);
        Found++;
        FString ClassName = A.Class.GetName().ToString();
        LogCatalog(Kind, ActorName, A.GetActorLocation(), ClassName, ClassName.Replace("BP_", "").Replace("_C", ""));
    }

    private void LogCatalog(const FString& Kind, const FString& Id, FVector L, const FString& ClassName, const FString& DisplayName)
    {
        const FString Shown = DisplayName.Replace("|", "/");
        Log(n"WSDS", f"[WSDS-CATALOG] {Kind}|{Id}|{int(L.X)}|{int(L.Y)}|{int(L.Z)}|{ClassName}|{Shown}");
    }

    // ---- client: export the map image ----
    // The in-game map is an 8x8 grid of tiles (WBP_WorldMap.SplitMapTextures, index = column + row * 8) cut
    // from one 8192x8192 image; each tile is exported as tile_NN.png and stitched together offline.
    private TArray<TSoftObjectPtr<UTexture2D>> Tiles;
    private int TilesLoaded = 0;
    private int ExportAttempts = 0;
    private bool bExportChecked = false;
    private float ClientSurveyStep = 0;
    private float ClientSurveyWait = 0;
    private float ExportWait = 0;
    private float ExportAfterLoad = -1;

    private void ExportMap()
    {
        APlayerCharacter Player = Cast<APlayerCharacter>(Gameplay::GetPlayerPawn(0));
        UWorldMapWidget MapWidget;
        int Specs = 0;
        int Toggles = 0;
        if (Player != nullptr && Player.AbilityComp != nullptr)
        {
            for (auto Spec : Player.AbilityComp.ActivatableAbilities.Items)
            {
                Specs++;
                UMapToggleAbility Toggle = Cast<UMapToggleAbility>(Spec.Ability);
                if (Toggle == nullptr)
                    continue;
                Toggles++;
                if (Toggle.WorldMapWidgetClass.Get() != nullptr)
                    MapWidget = Cast<UWorldMapWidget>(Toggle.WorldMapWidgetClass.DefaultObject);
            }
        }
        if (MapWidget == nullptr || MapWidget.SplitMapTextures.Num() == 0)
        {
            ExportAttempts++;
            Log(n"WSDS", f"[WSDS-EXPORT] attempt {ExportAttempts}: player={Player != nullptr} specs={Specs} toggles={Toggles} widget={MapWidget != nullptr}");
            if (ExportAttempts < 12)
                ExportDelay = 5.0;
            else
                Log(n"WSDS", "[WSDS-MAPINFO] {\"error\":\"map widget tiles not found\"}");
            return;
        }
        Tiles = MapWidget.SplitMapTextures;
        TilesLoaded = 0;
        for (TSoftObjectPtr<UTexture2D> Tile : Tiles)
            Tile.LoadAsync(FOnSoftObjectLoaded(this, n"OnTileLoaded"));
    }

    // Loaded tiles are held here (strong references) until they are exported.
    UPROPERTY()
    private TArray<UTexture2D> LoadedTiles;
    private TArray<FString> LoadedPaths;

    UFUNCTION()
    private void OnTileLoaded(UObject Loaded)
    {
        TilesLoaded++;
        UTexture2D Texture = Cast<UTexture2D>(Loaded);
        if (Texture != nullptr)
        {
            LoadedTiles.Add(Texture);
            LoadedPaths.Add(Texture.GetPathName());
        }
        if (TilesLoaded == Tiles.Num())
            ExportAfterLoad = 15.0; // give mip streaming time to bring in full resolution
    }

    private void ExportTiles()
    {
        int W = 0;
        int H = 0;
        int Exported = 0;
        for (int i = 0; i < Tiles.Num(); i++)
        {
            const int TileIndex = LoadedPaths.FindIndex(Tiles[i].ToString());
            if (TileIndex < 0)
            {
                Log(n"WSDS", f"[WSDS-EXPORT] tile {i} not loaded: {Tiles[i].ToString()}");
                continue;
            }
            UTexture2D Texture = LoadedTiles[TileIndex];
            Exported++;
            W = Texture.Blueprint_GetSizeX();
            H = Texture.Blueprint_GetSizeY();
            UTextureRenderTarget2D Target = Rendering::CreateRenderTarget2D(W, H, ETextureRenderTargetFormat::RTF_RGBA8_SRGB);
            UCanvas Canvas;
            FVector2D Size;
            FDrawToRenderTargetContext Context;
            Rendering::BeginDrawCanvasToRenderTarget(Target, Canvas, Size, Context);
            Canvas.DrawTexture(Texture, FVector2D(0, 0), Size, FVector2D(0, 0), FVector2D(1, 1), FLinearColor::White, EBlendMode::BLEND_Opaque);
            Rendering::EndDrawCanvasToRenderTarget(Context);
            const FString Index = i < 10 ? f"0{i}" : f"{i}";
            Rendering::ExportRenderTarget(Target, ExportDir, f"tile_{Index}.png");
        }
        TArray<AWorldMap> Maps;
        GetAllActorsOfClass(Maps);
        FString Bounds = "\"upperLeft\":null,\"levelSize\":null";
        if (Maps.Num() > 0)
            Bounds = f"\"upperLeft\":[{int(Maps[0].UpperLeftBound.X)},{int(Maps[0].UpperLeftBound.Y)}],\"levelSize\":[{int(Maps[0].LevelSize.X)},{int(Maps[0].LevelSize.Y)}]";
        const int Grid = int(Math::Sqrt(Tiles.Num()));
        Log(n"WSDS", f"[WSDS-MAPINFO] {{{Bounds},\"tiles\":{Tiles.Num()},\"grid\":{Grid},\"tile\":[{W},{H}]}}");
    }
};
