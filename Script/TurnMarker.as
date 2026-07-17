class ATurnMarker : AActor
{
    UPROPERTY(DefaultComponent, RootComponent)
    USceneComponent DefaultSceneComponent;

    UPROPERTY(DefaultComponent, Attach = DefaultSceneComponent)
    UWidgetComponent Widget;

    UFUNCTION(BlueprintEvent)
    void UpdateTurnMarker(FVector WorldLocation, int Distance, int Day)
    {
        //override in BP_TurnMarker
    }

    UFUNCTION(BlueprintEvent)
    void SetLandingState(ETurnMovementType MovementType)
    {
        //override in BP_TurnMarker
    }
}