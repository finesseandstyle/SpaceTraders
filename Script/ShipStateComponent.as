class UShipStateComponent : UActorComponent
{
    UPROPERTY() float HullPoints = 300;
    UPROPERTY() float ShipSpeed = 300;

    UFUNCTION(BlueprintOverride)
    void BeginPlay()
    {
        SetComponentTickEnabled(false);
    }

    //Returns the real speed of the ship in Unreal Units, to be used in the TurnBasedMovement comp
    UFUNCTION()
    float GetUUSpeed()
    {
        return ShipSpeed * 10;
    }
}