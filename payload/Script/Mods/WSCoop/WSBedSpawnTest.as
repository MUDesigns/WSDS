// Developer fixture for bed spawn points (admin `bedtest ...`, only with -WSDevTools).
namespace WSBedSpawnTest
{
    const FString BedClassPath = "/Game/Gameplay/Building/Categories/Furniture/BuildingPiece_SM_F_Bed_01_A.BuildingPiece_SM_F_Bed_01_A_C";

    ABuilding NearestBed(const FVector& Location, float MaxDistance)
    {
        TArray<ABuilding> Buildings;
        GetAllActorsOfClass(Buildings);
        ABuilding Best = nullptr;
        float BestDist = MaxDistance;
        for (ABuilding B : Buildings)
        {
            if (!IsValid(B) || B.IsPreviewBuilding() || !WSBedSpawn::IsBed(B))
                continue;
            const float D = B.GetActorLocation().Distance(Location);
            if (D < BestDist)
            {
                BestDist = D;
                Best = B;
            }
        }
        return Best;
    }

    FString Run(const FString& Action, APlayerCharacter P)
    {
        UWSBedSpawnSubsystem Sub = WSBedSpawn::GetSubsystem();
        if (Action == "scan")
        {
            if (Sub != nullptr)
                Sub.Refresh();
            TArray<ABuilding> Buildings;
            GetAllActorsOfClass(Buildings);
            TArray<ABuildingChunk> Chunks;
            GetAllActorsOfClass(Chunks);
            int Beds = 0;
            for (ABuilding B : Buildings)
            {
                if (WSBedSpawn::IsBed(B))
                {
                    Beds++;
                    WSCoop::Info(f"BEDTEST bed {B.GetName()} class={B.Class.GetName()} at {B.GetActorLocation()} preview={B.IsPreviewBuilding()} chunkHasInstance={WSBedSpawn::ChunkHasInstanceAt(B.GetActorLocation())}");
                }
            }
            for (ABuildingChunk C : Chunks)
            {
                int N = 0;
                for (UInstancedActorComponent Comp : C.InstancedActorComponents)
                {
                    if (Comp == nullptr)
                        continue;
                    N += Comp.InstanceTransforms.Num();
                    if (Comp.InstanceTransforms.Num() > 0)
                        WSCoop::Info(f"BEDTEST chunk {C.GetName()} at {C.GetActorLocation()} comp {Comp.GetName()} class {Comp.GetActorClass()} instances {Comp.InstanceTransforms.Num()}");
                }
            }
            return f"buildings={Buildings.Num()} beds={Beds} chunks={Chunks.Num()} markers={(Sub != nullptr ? Sub.NumMarkers() : -1)}";
        }
        if (P == nullptr)
            return "FAIL no spawned player";

        if (Action == "place")
        {
            ABuildingManager BuildingManager = AGameManager::Get(ABuildingManager);
            UClass BedClass = Cast<UClass>(LoadObject(UClass, BedClassPath));
            if (BuildingManager == nullptr || BedClass == nullptr)
                return f"FAIL manager={BuildingManager != nullptr} class={BedClass != nullptr}";
            TSubclassOf<ABuilding> BuildingClass = BedClass;
            const FVector Where = P.GetCapsuleBottomLocation() + P.GetActorForwardVector() * 230.0;
            BuildingManager.SpawnBuilding(BuildingClass, Where, FRotator(0, P.GetActorRotation().Yaw, 0));
            if (Sub != nullptr)
                Sub.Refresh();
            ABuilding Bed = NearestBed(Where, 200);
            return Bed != nullptr ? f"placed {Bed.GetName()} at {Bed.GetActorLocation()}" : f"FAIL no bed actor after SpawnBuilding at {Where}";
        }
        if (Action == "set")
        {
            if (Sub != nullptr)
                Sub.Refresh();
            AWSBedMarker Marker = Sub != nullptr ? Sub.NearestMarker(P.GetActorLocation()) : nullptr;
            if (Marker == nullptr)
                return "FAIL no bed marker";
            UInteractorComponent Interactor = UInteractorComponent::Get(P);
            const FInteractionContext Context(Interactor, Marker.Interactable, EInteractionType::OnActivated);
            const bool bOk = Marker.Interactable.Interact(Context);
            return bOk ? f"interacted ({Marker.GetActorLocation().Distance(P.GetActorLocation()):.0f} cm away): {WSBedSpawn::Describe(P)}" : f"FAIL interact refused at {Marker.GetActorLocation().Distance(P.GetActorLocation()):.0f} cm";
        }
        if (Action == "status")
            return WSBedSpawn::Describe(P);
        if (Action == "kill")
        {
            P.Kill();
            return f"killed {WSCoop::PlayerName(P)} at {P.GetActorLocation()}";
        }
        if (Action == "respawn")
        {
            const bool bOk = WSBedSpawn::TeleportToBed(P);
            return bOk ? f"teleport requested from {P.GetActorLocation()}" : "FAIL no valid bed";
        }
        if (Action == "destroy")
        {
            ABuilding Bed = NearestBed(P.GetActorLocation(), 3000);
            UBuildingComponent BuildingComp = UBuildingComponent::Get(P);
            if (Bed == nullptr || BuildingComp == nullptr)
                return "FAIL no bed near / no building component";
            BuildingComp.DestroyBuilding(Bed);
            return f"destroyed bed: {WSBedSpawn::Describe(P)}";
        }
        if (Action == "where")
            return f"{WSCoop::PlayerName(P)} at {P.GetActorLocation()}";
        return "FAIL unknown action";
    }
}
