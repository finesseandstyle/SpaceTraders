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

    //Not advisable way to do this, TODO: find a better way of finding the main mesh of a game object
    UFUNCTION()
    UStaticMeshComponent GetMainMesh()
    {
        return Cast<UStaticMeshComponent>(FindComponentByTag(UStaticMeshComponent, n"MainMesh"));
    }
}