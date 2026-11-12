class AGameObject : APawn
{
    UPROPERTY(DefaultComponent, RootComponent) USphereComponent Sphere;
    default Sphere.SphereRadius = 120;
    //Might need a Faction variable here instead of it residing on ShipStateComponent, could be hand

    UPROPERTY()//ExposeOnSpawn)
    FGameplayTag ObjectType = GameplayTags::GameObject_Ship;
    
    UPROPERTY(ExposeOnSpawn)
    float ZLevel;

    UFUNCTION(BlueprintEvent)
    void TurnUpdate()
    {
        //Body
    }

    UFUNCTION(BlueprintEvent)
    void TurnPause()
    {
        //Body
    }

    UFUNCTION(BlueprintEvent)
    void TurnResume()
    {
        //Body
    }

    UFUNCTION(BlueprintOverride)
    void BeginPlay()
    {
        auto TRS = UTurnResolutionSubsystem::Get();
        TRS.GameObjects.Add(this);

        FGameplayTag Race;
        if (ObjectType == GameplayTags::GameObject_Ship)
            Race = GetComponentByClass(UShipStateComponent).Faction;

        TRS.OnSmallObjectSpawned.Broadcast(this.RootComponent, ObjectType, Race);
    }

    UFUNCTION(BlueprintOverride)
    void Destroyed()
    {
        UTurnResolutionSubsystem::Get().GameObjects.Remove(this);
        UTurnResolutionSubsystem::Get().OnSmallObjectDestroyed.Broadcast(this.RootComponent);
    }

    //Not advisable way to do this, TODO: find a better way of finding the main mesh of a game object
    UFUNCTION()
    UStaticMeshComponent GetMainMesh()
    {
        return Cast<UStaticMeshComponent>(FindComponentByTag(UStaticMeshComponent, n"MainMesh"));
    }


};