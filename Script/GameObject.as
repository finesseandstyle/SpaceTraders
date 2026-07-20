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
    
    
}