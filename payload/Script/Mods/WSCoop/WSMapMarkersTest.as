// Developer fixtures for map markers (admin `markertest ...` with -WSDevTools; client flag -WSMarkerUITest).
namespace WSMapMarkersTest
{
    FString JoinAll(const TArray<FString>& Items, const FString& Sep)
    {
        FString Out = "";
        for (int i = 0; i < Items.Num(); i++)
            Out += (i > 0 ? Sep : "") + Items[i];
        return Out;
    }

    // markertest list | set <player> [dx dy] [type] | clear <player> | ping <player> [dx dy] | kill <player>
    //            | deaths | sleep <player> | sleepers | quickstack <player> | infos
    FString Run(const TArray<FString>& Args, APlayerCharacter P)
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        if (Manager == nullptr)
            return "FAIL no manager";
        const FString Action = Args[1];
        const FString Sep = "; ";
        if (Action == "list")
        {
            const FString All = WSMapMarkersTest::JoinAll(Manager.MapMarkers, Sep);
            const FString PingList = WSMapMarkersTest::JoinAll(Manager.Pings, Sep);
            return f"enabled={Manager.bMapMarkersEnabled} markers={Manager.MapMarkers.Num()}: {All} | pings={Manager.Pings.Num()}: {PingList}";
        }
        if (Action == "deaths")
            return f"deaths={Manager.DeathMarkers.Num()}: {WSMapMarkersTest::JoinAll(Manager.DeathMarkers, Sep)}";
        if (Action == "infos")
            return f"infos={Manager.PlayerInfos.Num()}: {WSMapMarkersTest::JoinAll(Manager.PlayerInfos, Sep)} hour={WSSleep::Hour()} night={WSSleep::IsNight()} skips={Manager.NightSkips}";
        if (Action == "sleepers")
            return f"sleepers={UWSSleepSubsystem::Get().NumSleepers()} hour={WSSleep::Hour()}";
        if (P == nullptr)
            return "FAIL no such player";
        APlayerController PC = Cast<APlayerController>(P.Controller);
        const float DX = Args.Num() >= 5 ? float(String::Conv_StringToDouble(Args[3])) : 3000.0;
        const float DY = Args.Num() >= 5 ? float(String::Conv_StringToDouble(Args[4])) : 0.0;
        if (Action == "set")
        {
            const FString Type = Args.Num() >= 6 ? Args[5] : "meet";
            WSMapMarkers::ServerEdit(PC, P.GetActorLocation() + FVector(DX, DY, 0), Type, -1);
            const FString All = WSMapMarkersTest::JoinAll(Manager.MapMarkers, Sep);
            return f"markers={Manager.MapMarkers.Num()}: {All}";
        }
        if (Action == "clear")
        {
            WSMapMarkers::ServerSet(PC, FVector::ZeroVector, true);
            return f"markers={Manager.MapMarkers.Num()}";
        }
        if (Action == "ping")
        {
            WSMapMarkers::OnVanillaPing(P, nullptr, P.GetActorLocation() + FVector(DX, DY, 0));
            return f"pings={Manager.Pings.Num()}: {WSMapMarkersTest::JoinAll(Manager.Pings, Sep)}";
        }
        if (Action == "kill")
        {
            P.AbilityComp.SetAttributeBaseValue(UHealthAttributeSet::GetHealthAttribute(), 0);
            if (P.IsAlive())
                P.AbilityComp.AddGameplayTag(GameplayTags::Status_Dead);
            return f"alive={P.IsAlive()}";
        }
        if (Action == "sleep")
        {
            UWSSleepSubsystem::Get().Lie(P);
            return f"sleepers={UWSSleepSubsystem::Get().NumSleepers()} hour={WSSleep::Hour()} skips={Manager.NightSkips}";
        }
        if (Action == "chest")
        {
            // A chest next to the player, seeded with the stack in the player's hotbar slot 1.
            UClass ChestClass = Cast<UClass>(LoadObject(UClass, "/Game/Gameplay/Crafting/Chest/BP_Chest.BP_Chest_C"));
            if (ChestClass == nullptr)
                return "FAIL no chest class";
            AActor Chest = SpawnActor(ChestClass, P.GetActorLocation() + FVector(250, 0, -80), FRotator(0, 0, 0));
            UInventoryComponent Store = Chest != nullptr ? UInventoryComponent::Get(Chest) : nullptr;
            if (Store == nullptr)
                return "FAIL chest has no inventory";
            UItemStack Seed = P.InventoryComp.GetItemStackAtSlot(1);
            if (Seed != nullptr)
                Store.TransferItemStack(Seed);
            const FString SeedName = Seed != nullptr ? Seed.GetItemTag().ToString() : "nothing";
            return f"chest {Chest.GetName()} at {Chest.GetActorLocation()} seeded with {SeedName}, types={Store.GetAllItemTypes().Num()}";
        }
        if (Action == "bag")
        {
            FString Out = "";
            for (int Slot = 0; Slot < P.InventoryComp.GetCapacity(); Slot++)
            {
                UItemStack S = P.InventoryComp.GetItemStackAtSlot(Slot);
                if (S != nullptr)
                    Out += f" {Slot}:{S.GetItemTag().ToString()}x{S.GetStackSize()}";
            }
            return f"bag{Out}";
        }
        if (Action == "reroll")
        {
            // Needs: give <player> Items.Wand_Master 1 and Items.SpiritDustBrilliant N first.
            UItemStack Weapon = nullptr;
            for (int Slot = 0; Slot < P.InventoryComp.GetCapacity(); Slot++)
            {
                UItemStack S = P.InventoryComp.GetItemStackAtSlot(Slot);
                if (WSWeaponReroll::IsMasterWeapon(S))
                    Weapon = S;
            }
            if (Weapon == nullptr)
                return "FAIL no master weapon in the bag";
            UClass StationClass = Cast<UClass>(LoadObject(UClass, "/Game/Gameplay/Crafting/Refiner/ItemCrafting/BP_ItemCraftingStation.BP_ItemCraftingStation_C"));
            AItemCraftingWorkstation Station = StationClass != nullptr ? Cast<AItemCraftingWorkstation>(SpawnActor(StationClass, P.GetActorLocation() + FVector(-250, 0, -80), FRotator(0, 0, 0))) : nullptr;
            if (Station == nullptr)
                return "FAIL no station";
            UItemRuntimeFragment_Rarity Rarity = Weapon.GetRuntimeFragment_Rarity();
            if (Rarity.GetRarity() == EItemRarity::Common)
                Rarity.SetRarity(EItemRarity::Epic);
            Station.GetItemStackCraftingComponent().SetCurrentCraftingItemStack(Weapon);
            const FString Before = WSWeaponReroll::StatLines(Rarity).Replace("\n", "; ");
            const int DustBefore = WSWeaponReroll::DustOwned(Station, Weapon);
            WSWeaponReroll::ServerReroll(Cast<APlayerController>(P.Controller), Station);
            const FString After = WSWeaponReroll::StatLines(Rarity).Replace("\n", "; ");
            const int DustAfter = WSWeaponReroll::DustOwned(Station, Weapon);
            return f"{Weapon.GetItemTag()} {Rarity.GetRarity()}: [{Before}] -> [{After}] dust {DustBefore} -> {DustAfter}";
        }
        if (Action == "stationselect")
        {
            TArray<AItemCraftingWorkstation> Stations;
            GetAllActorsOfClass(Stations);
            AItemCraftingWorkstation Best = nullptr;
            for (AItemCraftingWorkstation St : Stations)
            {
                if (Best == nullptr || St.GetActorLocation().Distance(P.GetActorLocation()) < Best.GetActorLocation().Distance(P.GetActorLocation()))
                    Best = St;
            }
            for (int Slot = 0; Slot < P.InventoryComp.GetCapacity() && Best != nullptr; Slot++)
            {
                UItemStack S = P.InventoryComp.GetItemStackAtSlot(Slot);
                if (WSWeaponReroll::IsMasterWeapon(S))
                {
                    Best.GetItemStackCraftingComponent().SetCurrentCraftingItemStack(S);
                    return f"selected {S.GetItemTag()} at {Best.GetName()}";
                }
            }
            return "FAIL no station or weapon";
        }
        if (Action == "famsalvage")
        {
            // Needs: give <player> Items.FamiliarBompus 1 (or any familiar item) first.
            UItemStack Familiar = nullptr;
            for (int Slot = 0; Slot < P.InventoryComp.GetCapacity(); Slot++)
            {
                UItemStack S = P.InventoryComp.GetItemStackAtSlot(Slot);
                if (WSFamiliarSalvage::IsFamiliar(S))
                    Familiar = S;
            }
            if (Familiar == nullptr)
                return "FAIL no familiar in the bag";
            UClass StationClass = Cast<UClass>(LoadObject(UClass, "/Game/Gameplay/Crafting/Refiner/Salvage/BP_SalvageStation.BP_SalvageStation_C"));
            ASalvageWorkStation Station = StationClass != nullptr ? Cast<ASalvageWorkStation>(SpawnActor(StationClass, P.GetActorLocation() + FVector(0, -250, -80), FRotator(0, 0, 0))) : nullptr;
            if (Station == nullptr)
                return "FAIL no salvage station";
            UInventoryComponent Input = nullptr;
            for (UActorComponent C : Station.GetComponentsByClass(UInventoryComponent))
            {
                UInventoryComponent I = Cast<UInventoryComponent>(C);
                if (I != nullptr && I.GetCapacity() == 8)
                    Input = I;
            }
            if (Input == nullptr)
                return "FAIL no input inventory";
            UItemRuntimeFragment_FamiliarInfo Info = Cast<UItemRuntimeFragment_FamiliarInfo>(Familiar.GetRuntimeFragment(UItemRuntimeFragment_FamiliarInfo));
            const FString Desc = f"{Familiar.GetItemTag()} level {Info.GetLevel()} rarity {Familiar.GetItemRarity()} salvageable={ItemUtils::IsItemSalvagable(Familiar)}";
            Input.TransferItemStack(Familiar);
            Station.SalvageItems();
            FString Out;
            for (UItemStack S : Station.GetOutputInventoryComponent().AllItemStacks)
                Out += f" {S.GetItemTag()}x{S.GetStackSize()}";
            return f"{Desc} -> input left {Input.AllItemStacks.Num()}, output:{Out}";
        }
        if (Action == "quickstack")
        {
            WSQuickStack::ServerQuickStack(PC);
            return "done (see log)";
        }
        return "FAIL unknown action";
    }
}

// Client flag -WSMarkerUITest: places a marker through the same call a map click makes, reports what this game
// shows (beam, compass icons and labels, map element), then removes it through the map-icon click path.
UCLASS()
class UWSMapMarkersUITest : UScriptWorldSubsystem
{
    private float Clock = 0;
    private int Step = 0;
    private bool bEnabled = false;

    UFUNCTION(BlueprintOverride)
    void OnWorldBeginPlay()
    {
        bEnabled = !System::IsServer() && System::ParseParam(System::GetCommandLine(), "WSMarkerUITest");
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaTime)
    {
        APawn P = Game::GetLocalPlayer();
        if (!bEnabled || P == nullptr)
            return;
        Clock += DeltaTime;
        const float Wait = String::Conv_StringToDouble(WSDS::Param("WSMarkerStepSeconds", "6"));
        if (Clock < (Step == 0 ? 25.0 : Wait))
            return;
        Clock = 0;
        Step++;
        if (Step == 1)
        {
            APlayerCameraManager Cam = Gameplay::GetPlayerCameraManager(0);
            const float Yaw = (Cam != nullptr ? Cam.GetCameraRotation().Yaw : P.ActorRotation.Yaw) + String::Conv_StringToDouble(WSDS::Param("WSBeamYaw", "0"));
            const FVector Spot = P.ActorLocation + FRotator(0, Yaw, 0).ForwardVector * String::Conv_StringToDouble(WSDS::Param("WSMarkerDistance", "4000"));
            const FString Type = WSDS::Param("WSMarkerType", "meet");
            WSMapMarkers::View().Select(Type);
            WSCoop::Info(f"MARKERUI placing a {Type} marker at {Spot} the way a map click does");
            WSMapMarkers::OnMapClicked(Spot);
        }
        else if (Step == 2 || Step == 3)
            Report();
        else if (Step == 4 && System::ParseParam(System::GetCommandLine(), "WSMarkerRemove"))
        {
            AWorldMapManager MapManager = AGameManager::Get(AWorldMapManager);
            if (MapManager != nullptr)
            {
                for (const FRegisteredWorldMapElement& E : MapManager.GetRegisteredMapElements())
                {
                    if (E.UniqueId.ToString().StartsWith(WSMapMarkers::ElementPrefix + "m_"))
                    {
                        WSCoop::Info(f"MARKERUI clicking own map icon {E.UniqueId}");
                        WSMapMarkers::OnElementClicked(E.UniqueId);
                    }
                }
            }
        }
        else if (Step == 5)
        {
            Report();
            bEnabled = false;
        }
    }

    void Report()
    {
        AWSCoopManager Manager = WSCoop::GetManager();
        FString Text = f"MARKERUI manager={Manager != nullptr}";
        if (Manager != nullptr)
        {
            const FString Sep = "; ";
            const FString All = WSMapMarkersTest::JoinAll(Manager.MapMarkers, Sep);
            const FString Deaths = WSMapMarkersTest::JoinAll(Manager.DeathMarkers, Sep);
            const FString PingList = WSMapMarkersTest::JoinAll(Manager.Pings, Sep);
            Text += f" enabled={Manager.bMapMarkersEnabled} entries={Manager.MapMarkers.Num()} [{All}] deaths=[{Deaths}] pings=[{PingList}] version={Manager.ServerModVersion} infos={Manager.PlayerInfos.Num()}";
        }
        TArray<AActor> Beams;
        UClass BeamClass = Cast<UClass>(LoadObject(UClass, WSMapMarkers::BeamClassPath));
        if (BeamClass != nullptr)
            GetAllActorsOfClass(BeamClass, Beams);
        Text += f" beams={Beams.Num()}";
        AWorldMapManager MapManager = AGameManager::Get(AWorldMapManager);
        int Elements = 0;
        if (MapManager != nullptr)
        {
            for (const FRegisteredWorldMapElement& E : MapManager.GetRegisteredMapElements())
            {
                if (E.UniqueId.ToString().StartsWith(WSMapMarkers::ElementPrefix))
                    Elements++;
            }
        }
        Text += f" mapElements={Elements}";
        UHUDWidget HUD = Game::GetHUDWidget();
        int Pinned = 0;
        FString Labels = "";
        if (HUD != nullptr && HUD.Widget_Compass != nullptr)
        {
            TArray<UWidget> All;
            HUD.Widget_Compass.GetAllWidgets(All);
            for (UWidget W : All)
            {
                UCompassIconWidget Icon = Cast<UCompassIconWidget>(W);
                if (Icon != nullptr && WSMapMarkers::IsPinnedIcon(Icon))
                    Pinned++;
                UTextBlock T = Cast<UTextBlock>(W);
                if (T != nullptr && T.GetText().ToString().Contains(" m"))
                    Labels += f" '{T.GetText().ToString()}'";
            }
        }
        Text += f" pinnedCompassIcons={Pinned} labels:{Labels}";
        if (HUD != nullptr && HUD.Widget_Compass != nullptr)
        {
            FString Clip = f"compass clip={HUD.Widget_Compass.GetClipping()} size={HUD.Widget_Compass.GetCachedGeometry().GetLocalSize()}";
            TArray<UWidget> All2;
            HUD.Widget_Compass.GetAllWidgets(All2);
            for (UWidget W : All2)
            {
                if (W.GetClipping() != EWidgetClipping::Inherit)
                    Clip += f" [{W.GetName()} {W.GetClipping()} {W.GetCachedGeometry().GetLocalSize()}]";
                UCompassIconWidget Icon = Cast<UCompassIconWidget>(W);
                if (Icon != nullptr && WSMapMarkers::IsPinnedIcon(Icon))
                {
                    TArray<UWidget> Inner;
                    Icon.GetAllWidgets(Inner);
                    for (UWidget I : Inner)
                    {
                        UTextBlock T = Cast<UTextBlock>(I);
                        if (T != nullptr)
                            Clip += f" label '{T.GetText().ToString()}' vis={T.IsVisible()} size={T.GetCachedGeometry().GetLocalSize()} parent={T.GetParent() != nullptr}";
                    }
                    Clip += f" icon {Icon.GetName()} clip={Icon.GetClipping()} opacity={Icon.GetRenderOpacity()} vis={Icon.IsVisible()}";
                }
            }
            WSCoop::Info(f"MARKERUI {Clip}");
        }
        WSCoop::Info(Text);
    }
};
