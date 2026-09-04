class AGameObject : APawn
{
    UPROPERTY(DefaultComponent, RootComponent) 
    USphereComponent Sphere;
    default Sphere.SphereRadius = 120;

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
        ATopDown_GameState GameState = Cast<ATopDown_GameState>(Gameplay::GetGameState());
        GameState.GameObjects.Add(this);

        FGameplayTag Race;
        if (ObjectType == GameplayTags::GameObject_Ship)
            Race = GetComponentByClass(UShipStateComponent).Faction;

        GameState.OnSmallObjectSpawned.Broadcast(this.RootComponent, ObjectType, Race);
    }

    UFUNCTION(BlueprintOverride)
    void Destroyed()
    {
        Cast<ATopDown_GameState>(Gameplay::GetGameState()).GameObjects.Remove(this);
        Cast<ATopDown_GameState>(Gameplay::GetGameState()).OnSmallObjectDestroyed.Broadcast(this.RootComponent);
    }

    //Not advisable way to do this, TODO: find a better way of finding the main mesh of a game object
    UFUNCTION()
    UStaticMeshComponent GetMainMesh()
    {
        return Cast<UStaticMeshComponent>(FindComponentByTag(UStaticMeshComponent, n"MainMesh"));
    }


};