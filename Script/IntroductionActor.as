class AIntroductionActor : AActor
{
    UPROPERTY()
    float NewProp = 5.0;

    UPROPERTY()
    float CountdownDuration = 5.0;

    UPROPERTY(DefaultComponent)
    UBHP_ProjectileMovementComponent MissileComp;

    UPROPERTY(DefaultComponent)
    USixDOFMovementComponent MovementComp;
}