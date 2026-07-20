event void FOnItemPickedUp(AActor LootObject, FGameItem Item);

class ULootComponent : UActorComponent
{
    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------

    // Item is collected when it reaches within this radius of the ship. */
    UPROPERTY() float SnapCollectRadius = 60.0;
    UPROPERTY() bool bCanBePickedUp = true;
    UPROPERTY(ExposeOnSpawn) FGameItem Item;

    /**
     * Fired once when collected. CollectedItem is this component's owner —
     * passed explicitly so listeners are safe even if DestroyActor is also
     * bound to this delegate.
     */
    UPROPERTY() FOnItemPickedUp OnItemPickedUp;

    // -------------------------------------------------------------------------
    // Internal State
    // -------------------------------------------------------------------------

    private AGameObject CurrentPuller = nullptr;
    private float CurrentPullerScore = -1.0;
    private bool bIsCollected = false;

    private const float ContestHysteresis = 1.5;

    // -------------------------------------------------------------------------
    // Contention API
    // -------------------------------------------------------------------------

    bool TryClaimAsPuller(AGameObject BiddingShip, const float Score)
    {
        if (!bCanBePickedUp || bIsCollected || BiddingShip == nullptr)
            return false;

        if (CurrentPuller == BiddingShip)
        {
            CurrentPullerScore = Score;
            return true;
        }

        if (CurrentPuller == nullptr)
        {
            CurrentPuller = BiddingShip;
            CurrentPullerScore = Score;
            return true;
        }

        if (Score > CurrentPullerScore * ContestHysteresis)
        {
            CurrentPuller = BiddingShip;
            CurrentPullerScore = Score;
            return true;
        }

        return false;
    }

    void ReleasePullerClaim(AGameObject ReleasingShip)
    {
        if (CurrentPuller == ReleasingShip)
        {
            CurrentPuller = nullptr;
            CurrentPullerScore = -1.0;
        }
    }

    /**
     * Move this item toward ShipLocation. Only executes for the current puller.
     * Calls MarkCollected() and returns true when SnapCollectRadius is reached.
     */
    bool UpdatePullMovement(AGameObject MovingShip, const FVector& ShipLocation, const float PullSpeed, const float DeltaTime)
    {
        if (MovingShip == nullptr || CurrentPuller != MovingShip || bIsCollected || !bCanBePickedUp)
            return false;

        
        AActor OwnerActor = GetOwner();
        if (OwnerActor == nullptr)
            return false;

        const FVector ItemLocation = OwnerActor.GetActorLocation();
        const FVector Direction = (ShipLocation - ItemLocation).GetSafeNormal();
        const float DistToShip = ItemLocation.Distance(ShipLocation);

        // Calculate a full, raw step based purely on velocity and time
        const float FullStep = PullSpeed * DeltaTime;

        // Determine the distance remaining until reaching the boundary
        const float DistanceToBoundary = DistToShip - SnapCollectRadius;

        // If our full frame step is going to match or exceed the boundary gap,
        // we bypass subtraction completely, snap it directly to the radius boundary, and collect.
        if (FullStep >= DistanceToBoundary)
        {
            MarkCollected(MovingShip);
            return true;
        }

        // Otherwise, we are safely far away; take a normal step
        OwnerActor.SetActorLocation(ItemLocation + Direction * FullStep);
        return false;
    }

    UFUNCTION()
    void MarkCollected(AGameObject CollectingShip)
    {
        if (bIsCollected)
            return;

        bIsCollected = true;
        bCanBePickedUp = false;
        CurrentPuller = nullptr;
        CurrentPullerScore = -1.0;

        AActor OwnerActor = GetOwner();
        OnItemPickedUp.Broadcast(OwnerActor, Item);
    }

    // -------------------------------------------------------------------------
    // Queries
    // -------------------------------------------------------------------------

    UFUNCTION()
    bool IsBeingPulled() const
    {
        return CurrentPuller != nullptr;
    }

    UFUNCTION()
    bool IsCollected() const
    {
        return bIsCollected;
    }

    UFUNCTION()
    AGameObject GetCurrentPuller() const
    {
        return CurrentPuller;
    }
}