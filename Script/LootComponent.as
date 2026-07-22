event void FOnItemPickedUp(AActor LootObject, FGameItem Item);

const float SnapCollectRadius = 30.0;
const float ContestHysteresis = 1.5;

class ULootComponent : UActorComponent
{
    // -------------------------------------------------------------------------
    // Configuration
    // -------------------------------------------------------------------------

    // Item is collected when it reaches within this radius of the ship. */
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

    private AActor CurrentPuller = nullptr;
    private float CurrentPullerScore = -1.0;
    private bool bIsCollected = false;


    // -------------------------------------------------------------------------
    // Contention API
    // -------------------------------------------------------------------------

    bool TryClaimAsPuller(AActor BiddingShip, const float Score)
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

    void ReleasePullerClaim(AActor ReleasingShip)
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
    bool UpdatePullMovement(AActor MovingShip, const FVector& ShipLocation, const float PullSpeed, const float DeltaTime)
    {
        if (MovingShip == nullptr || CurrentPuller != MovingShip || bIsCollected || !bCanBePickedUp)
            return false;

        AActor OwnerActor = GetOwner();
        if (OwnerActor == nullptr)
            return false;

        const FVector ItemLocation = OwnerActor.GetActorLocation();

        // Calculate full 3D vector and 2D ground distance
        const FVector FullVector = ShipLocation - ItemLocation;
        const float Dist2D = FVector2D(ItemLocation.X, ItemLocation.Y).Distance(FVector2D(ShipLocation.X, ShipLocation.Y));

        const float FullStep2D = PullSpeed * DeltaTime;
        const float DistanceToBoundary = Dist2D - SnapCollectRadius;

        if (FullStep2D >= DistanceToBoundary)
        {
            MarkCollected(MovingShip);
            return true;
        }

        // Scale 3D vector by the 2D step ratio so ground speed stays identical
        if (Dist2D > 0.001f)
        {
            const FVector StepVector = (FullVector / Dist2D) * FullStep2D;
            OwnerActor.SetActorLocation(ItemLocation + StepVector);
        }

        return false;
    }

    UFUNCTION()
    void MarkCollected(AActor CollectingShip)
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
    AActor GetCurrentPuller() const
    {
        return CurrentPuller;
    }
}