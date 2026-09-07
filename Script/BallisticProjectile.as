const float MaxBallisticSpeed = 5000.0;

class ABallisticProjectile : AGameObject
{
    default ObjectType = GameplayTags::GameObject_Projectile;
    default Sphere.SphereRadius = 25;
    default Sphere.CollisionObjectType = ECollisionChannel::Projectile;
    default Sphere.SetCollisionResponseToChannel(ECollisionChannel::ECC_Camera,         ECollisionResponse::ECR_Ignore);
    default Sphere.SetCollisionResponseToChannel(ECollisionChannel::ECC_WorldStatic,    ECollisionResponse::ECR_Overlap);
    default Sphere.SetCollisionResponseToChannel(ECollisionChannel::ECC_WorldDynamic,   ECollisionResponse::ECR_Overlap);
    default Sphere.SetCollisionResponseToChannel(ECollisionChannel::ECC_Pawn,           ECollisionResponse::ECR_Overlap);
    default Sphere.SetCollisionResponseToChannel(ECollisionChannel::ECC_PhysicsBody,    ECollisionResponse::ECR_Overlap);
    default Sphere.SetCollisionResponseToChannel(ECollisionChannel::ECC_Vehicle,        ECollisionResponse::ECR_Overlap);
    default Sphere.SetCollisionResponseToChannel(ECollisionChannel::ECC_Destructible,   ECollisionResponse::ECR_Overlap);
    default Sphere.SetCollisionResponseToChannel(ECollisionChannel::Projectile,         ECollisionResponse::ECR_Ignore);

    UPROPERTY(DefaultComponent, Attach = Sphere)   UStaticMeshComponent ProjectileMesh;
    default ProjectileMesh.RelativeScale3D = FVector(2.0);
    default ProjectileMesh.ComponentTags.Add(n"MainMesh");
    default ProjectileMesh.SetLightingChannels(false, true, false);

    UPROPERTY(DefaultComponent, Attach = ProjectileMesh) UNiagaraComponent ExhaustNS;
    default ExhaustNS.RelativeLocation = FVector(-11, 0.0, 0.0);
    default ExhaustNS.AutoActivate = false;

    UPROPERTY(DefaultComponent) UBHP_MissileMovementComponent BallisticMovement;
    default BallisticMovement.bAutoIgniteRocketMotor = false;
    default BallisticMovement.HomingRotationInterpSpeed = 9.0;
    default BallisticMovement.bRollProjectile = true;
    default BallisticMovement.MaxSpeed = MaxBallisticSpeed;
    default BallisticMovement.ProjectileGravityScale = 0.0;
    default BallisticMovement.bIsHomingProjectile = false;
    default BallisticMovement.HomingAccelerationMagnitude = 5000.0;

    UPROPERTY(ExposeOnSpawn) FProjectileDamageSpec Damage;
    UPROPERTY(ExposeOnSpawn) float InheritedSpeed;
    UPROPERTY(ExposeOnSpawn) UNiagaraSystem ImpactNS;

    private FVector OldVelocity;
    private float InitialTargetDot;
    private FVector Offset;

    UFUNCTION(BlueprintOverride)
    void ConstructionScript()
    {
        BallisticMovement.SetHomingTargetComponent(Damage.HomingTarget);
        BallisticMovement.InitialSpeed = InheritedSpeed;
        BallisticMovement.MaxSpeed = InheritedSpeed;
        InitialTargetDot = ((ActorLocation - Damage.HomingTarget.WorldLocation).GetSafeNormal().DotProduct(ActorForwardVector) + 1) * 0.5;
    }

    UFUNCTION(BlueprintOverride)
    void ActorBeginOverlap(AActor OtherActor)
    {
        if (GetOwner() == nullptr || OtherActor == GetOwner() || OtherActor == nullptr)
            return;

        AGameObject GameObject = Cast<AGameObject>(OtherActor);

        if (GameObject != nullptr && GameObject.ObjectType.MatchesTagExact(GameplayTags::GameObject_Ship))
        {
            UShipStateComponent ShipComp = OtherActor.GetComponentByClass(UShipStateComponent);
            FDamageSpec DamageSpec = GameLogic::CreateDamageSpec(ShipComp, Damage.DamageType, Damage.MinDamage, Damage.MaxDamage, Damage.Accuracy, Damage.ShieldBypass);
            FDamageCalculationOutput Output = ShipComp.ApplySelfDamage(DamageSpec);
            UTopDownPlannerComponent Planner = Gameplay::GetPlayerController(0).GetComponentByClass(UTopDownPlannerComponent);

            if (Planner != nullptr)
                Planner.DisplayDamageNumbers(ActorLocation, Output.HullDamage + Output.ShieldDamage);
            //Maybe move the DisplayDamageNumbers to a different place, it's kind of clunky to get it

            Niagara::SpawnSystemAttached(ImpactNS, OtherActor.RootComponent, n"None", (ActorLocation - OtherActor.ActorLocation), FRotator::ZeroRotator, EAttachLocation::KeepRelativeOffset, false);
            ExhaustNS.Deactivate();
            ProjectileMesh.ToggleVisibility();
            BallisticMovement.SetActive(false);
            //Delay
            System::SetTimer(this, n"K2_DestroyActor", 0.2, false);
        }

        //Ignore non-ship objects unless they were explicitly targeted
        if (GameObject != nullptr && (GameObject.ObjectType == GameplayTags::GameObject_Loot || GameObject.ObjectType == GameplayTags::GameObject_Asteroid) && Damage.HomingTarget == OtherActor.RootComponent)
        {
            OtherActor.DestroyActor();
            DestroyActor();
        }

        //TODO: Sun proximity should destroy the projectile
        
    }

    UFUNCTION(BlueprintOverride)
    void TurnPause()
    {
        OldVelocity = BallisticMovement.Velocity;
        BallisticMovement.SetActive(false);
    }

    UFUNCTION(BlueprintOverride)
    void TurnResume()
    {
        BallisticMovement.SetActive(true);
        BallisticMovement.Velocity = OldVelocity;
    }

    UFUNCTION(BlueprintOverride)
    void TurnUpdate()
    {
        if (Damage.HomingDelay_Turns == 1)
        {
            ExhaustNS.Activate();
            BallisticMovement.bIsHomingProjectile = true;
            Offset = ActorLocation + (GetActorRightVector() * FVector(1000) * FVector(InitialTargetDot)) + 
                (FVector(ActorLocation.Dist2D(Damage.HomingTarget.WorldLocation)) * (Damage.HomingTarget.WorldLocation - ActorLocation).GetSafeNormal() * (1 - InitialTargetDot));

            Damage.HomingDelay_Turns -= 1;
            BallisticMovement.IgniteRocketMotor();
            BallisticMovement.SetHomingPointOffActor(Offset);   
            BallisticMovement.MaxSpeed = MaxBallisticSpeed;
            System::SetTimer(this, n"HomeInOnActor", 0.5, false);

        }
        else
        {
            Damage.HomingDelay_Turns -= 1;
        }
    }
    
    UFUNCTION()
    void HomeInOnActor()
    {
        BallisticMovement.ClearHomingTarget();
        BallisticMovement.SetHomingTargetComponent(Damage.HomingTarget);
    }
}