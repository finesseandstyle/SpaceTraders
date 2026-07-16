class ACameraRig : APawn
{
    // --- Components ---
    UPROPERTY(DefaultComponent, RootComponent)
    USceneComponent RigRoot;

    UPROPERTY(DefaultComponent, Attach = RigRoot)
    USpringArmComponent SpringArm;

    UPROPERTY(DefaultComponent, Attach = SpringArm)
    UCameraComponent Camera;

    // --- Config ---
    UPROPERTY(Category = "Camera Config") float MinZoom = 3000;
    UPROPERTY(Category = "Camera Config") float MaxZoom = 23000;
    UPROPERTY(Category = "Camera Config") float ScrollSpeed = 2;
    UPROPERTY(Category = "Camera Config") float ZoomIncrement = 4000;
    UPROPERTY(Category = "Camera Config") float DefaultPitch = -80;
    UPROPERTY(Category = "Camera Config") float WithRotationPitch = -25;
    UPROPERTY(Category = "Camera Config") float ZLevel = 1100;
    UPROPERTY(Category = "Camera Config") float LookAhead = 900; // Max distance (in pixels/units) the camera will shift ahead
    UPROPERTY(Category = "Camera Config") float SwayDistance = 350;
    UPROPERTY(Category = "Camera Config") float SwayInterpSpeed = 1.5;
    UPROPERTY(Category = "Camera Config") float SwayFrequency = 1.5;
    UPROPERTY(Category = "Camera Config") float SmoothZoomSpeed = 2;
    UPROPERTY(Category = "Camera Config") bool bSmoothZoom = true;
    UPROPERTY(Category = "Camera Config") float RecenterDuration = 1;

    // --- State ---
    UPROPERTY(Category = "Camera State") bool IsFollowing = false;
    UPROPERTY(Category = "Camera State") AActor TargetToFollow = nullptr;
    UPROPERTY(Category = "Camera State") bool bRotateCamera = false;
    UPROPERTY(Category = "Camera State") bool bIsTurnPaused = true;
    UPROPERTY(Category = "Camera State") float SwayStrength = 0.0;
    UPROPERTY(Category = "Camera State") bool bIsTransitioningToFollow = false;
    UPROPERTY(Category = "Camera State") FVector TransitionStartLocation;
    UPROPERTY(Category = "Camera State") float TransitionElapsed = 0.0;
    UPROPERTY(Category = "Camera State") bool bIsTransitioningOffsetToZero = false;


    private float OldSpringArmLength, NewSpringArmLength;
    private FVector OldZoomLoc, NewZoomLoc, TargetPlayfieldLocation;
    private bool bIsZoomAnimating, bApplyZoomToCursor = false;


    UFUNCTION(BlueprintOverride)
    void BeginPlay()
    {
        SpringArm.TargetArmLength = 3000;
        SpringArm.bDoCollisionTest = false; // Prevents the camera from yanking inwards near assets
        OldSpringArmLength = SpringArm.TargetArmLength;
        NewSpringArmLength = OldSpringArmLength;

        // Set the Y rotation (Pitch) to -80 degrees to look down on the playfield grid
        SpringArm.SetWorldRotation(FRotator(DefaultPitch, 0, 0));

        AddTickPrerequisiteComponent(SpringArm); // Ensures spring arm doesn't fight root tracking
        SetTickGroup(ETickingGroup::TG_PostPhysics); //no stuttering
    }

    //Has to be run on the PC with TickGroup = Post Physics
    UFUNCTION()
    void SmoothZoom(float DeltaSeconds)
    {
        if (bSmoothZoom && bIsZoomAnimating)
        {                
            // 1. Capture the length BEFORE this frame's interpolation step
            float OldLength = SpringArm.TargetArmLength;
            
            // 2. Advance the spring arm length interpolation
            float NewLength = Math::FInterpTo(OldLength, NewSpringArmLength, DeltaSeconds, 10);
            SpringArm.TargetArmLength = NewLength;

            // 3. Apply frame-by-frame cursor zoom scaling based on the actual delta change
            if (bApplyZoomToCursor && !Math::IsNearlyZero(OldLength))
            {
                float Ratio = NewLength / OldLength;
                FVector CurrentLoc = GetActorLocation();
                
                // Scale the distance between the camera and the cursor by this frame's zoom ratio
                FVector NewLoc = ((CurrentLoc - TargetPlayfieldLocation) * Ratio) + TargetPlayfieldLocation;
                NewLoc.Z = ZLevel; 
                
                SetActorLocation(NewLoc);
                //Print(f"Old Length: {OldLength}\nNew Length:{NewLength}\nRatio:{Ratio}\nCurrentLoc: {CurrentLoc}\n", 0);
                //Print(f"Target Loc: {TargetPlayfieldLocation}", 0);
            }
            
            // 4. Reset animation tracking when we get within 1 unit of the target
            if (Math::IsNearlyEqual(NewLength, NewSpringArmLength, 1.0))
            {
                SpringArm.TargetArmLength = NewSpringArmLength;
                bIsZoomAnimating = false;
                bApplyZoomToCursor = false;
            }
        }
        
    }

    UFUNCTION(BlueprintOverride)
    void Tick(float DeltaSeconds)
    {
        if (IsFollowing && TargetToFollow != nullptr)
        {
            FVector TargetLoc = TargetToFollow.GetActorLocation();
            TargetLoc.Z = ZLevel;

            if (bIsTransitioningToFollow)
            {
                TransitionElapsed += DeltaSeconds;
                float Alpha = Math::Clamp(TransitionElapsed / RecenterDuration, 0.0, 1.0);

                FVector InterpLoc = Math::EaseInOut(TransitionStartLocation, TargetLoc, Alpha, 3);
                SetActorLocation(InterpLoc);

                if (Alpha >= 1.0)
                {
                    bIsTransitioningToFollow = false;
                    SetActorLocation(TargetLoc);
                }
            }
            else
            {
                SetActorLocation(TargetLoc);
            }

            // Handle matching the tracking target's heading rotation
            if (bRotateCamera)
            {
                FRotator TargetRotation = TargetToFollow.GetActorRotation();
                FRotator CurrentRotation = GetActorRotation();
                
                float TargetYaw = TargetRotation.Yaw;
                float NewYaw = Math::RInterpTo(CurrentRotation, FRotator(0, TargetYaw, 0), DeltaSeconds, 3).Yaw;
                
                SetActorRotation(FRotator(0, NewYaw, 0));
            }

            FVector LookAheadVector = FVector::ZeroVector;
            FVector SwayVector = FVector::ZeroVector;
            // side-to-side sway
            if (!bIsTurnPaused)
            {
                FVector ShipForward = TargetToFollow.GetActorForwardVector();
                ShipForward.Z = 0;
                ShipForward.Normalize();

                // 💡 Convert the ship's world heading into the Camera Rig's local view space
                FVector LocalHeading = GetActorTransform().InverseTransformVector(ShipForward);
                LocalHeading.Normalize();

                // Establish our 16:9 Screen Dimension Coefficients
                // TODO: set up aspect ratio dynamically when windows changes.
                float HorizontalScale = 1.77;
                float VerticalScale = 1.00;

                // 💡 Calculate a dynamic modifier based on the camera view plane.
                // LocalHeading.Y represents Left/Right movement across your monitor screen.
                // LocalHeading.X represents Up/Down movement across your monitor screen.
                float AspectRatioMultiplier = Math::Lerp(VerticalScale, HorizontalScale, Math::Abs(LocalHeading.Y));
                
                // Push the look-ahead out, incorporating our dynamic aspect ratio modifier
                LookAheadVector = ShipForward * LookAhead * AspectRatioMultiplier;

                float TimeScale = Gameplay::GetRealTimeSeconds();
                float NewSway = Math::Sin(TimeScale * SwayFrequency) * SwayDistance;
                
                FVector ShipRight = TargetToFollow.GetActorRightVector();
                SwayVector = ShipRight * NewSway;
            }
            FVector DesiredTargetOffset = LookAheadVector + SwayVector;
            SpringArm.TargetOffset = Math::VInterpTo(SpringArm.TargetOffset, DesiredTargetOffset, DeltaSeconds, SwayInterpSpeed);
        }

        // Without this, panning after following is jarring
        if (bIsTransitioningOffsetToZero)
        {
            SpringArm.TargetOffset = Math::VInterpTo(SpringArm.TargetOffset, FVector::ZeroVector, DeltaSeconds, 10);
            SpringArm.SocketOffset = Math::VInterpTo(SpringArm.SocketOffset, FVector::ZeroVector, DeltaSeconds, 10);
            //Print(f"{SpringArm.TargetOffset} - {SpringArm.SocketOffset}", 0);

            if (SpringArm.TargetOffset.IsNearlyZero() && SpringArm.SocketOffset.IsNearlyZero())
            {
                SpringArm.TargetOffset = FVector::ZeroVector;
                SpringArm.SocketOffset = FVector::ZeroVector;
                bIsTransitioningOffsetToZero = false;
            }
        }
    }

    UFUNCTION()
    void SetRotatingCamera()
    {
        bRotateCamera = true;
        SpringArm.SetWorldRotation(FRotator(WithRotationPitch, 0, 0));
    }

    UFUNCTION()
    void SetDefaultCamera()
    {
        bRotateCamera = false;
        SpringArm.SetWorldRotation(FRotator(DefaultPitch, 0, 0));
        SetActorRotation(FRotator::ZeroRotator);
    }

    // Removes target from being followed
    UFUNCTION()
    void SetFreeCamera()
    {
        SetDefaultCamera();
        IsFollowing = false;
        TargetToFollow = nullptr;
        bIsTransitioningToFollow = false;
        TransitionElapsed = 0.0;
        bIsTransitioningOffsetToZero = true;
    }

    // Handles zooming, supporting zoom-to-cursor scaling math
    UFUNCTION()
    void UpdateZoom(bool bZoomToCursor, float InputAxis, FVector PlayfieldLocation)
    {
        if (Math::IsNearlyZero(InputAxis))
            return;

        // Calculate and clamp new zoom length
        NewSpringArmLength = NewSpringArmLength + (ZoomIncrement * InputAxis * -1);
        NewSpringArmLength = Math::Clamp(NewSpringArmLength, MinZoom, MaxZoom);
        
        // Cache cursor data for the active zoom lifecycle
        if (!IsFollowing && bZoomToCursor)
        {
            SetFreeCamera();
            TargetPlayfieldLocation = PlayfieldLocation;
            bApplyZoomToCursor = true;
        }
        else
        {
            bApplyZoomToCursor = false;
        }

        if (!bSmoothZoom)
        {
            float OldLength = SpringArm.TargetArmLength;
            SpringArm.TargetArmLength = NewSpringArmLength;     
            
            if (bApplyZoomToCursor && !Math::IsNearlyZero(OldLength))
            {
                FVector CurrentLoc = GetActorLocation();
                FVector NewLoc = ((CurrentLoc - TargetPlayfieldLocation) * (NewSpringArmLength / OldLength)) + TargetPlayfieldLocation;
                NewLoc.Z = ZLevel;
                SetActorLocation(NewLoc);
            }
        } 
        else
        {
            bIsZoomAnimating = true;
        }
    }   


    // Sets up a new target initialization loop
    UFUNCTION()
    void SetNewObjectToFollow(AActor NewTarget)
    {
        if (NewTarget == nullptr)
        {
            return;
        }

        TargetToFollow = NewTarget;
        IsFollowing = true;
        bIsTransitioningOffsetToZero = false; 

        if (bIsTurnPaused)
        {
            FVector InitialTargetLoc = NewTarget.GetActorLocation();
            InitialTargetLoc.Z = ZLevel;
            SetActorLocation(InitialTargetLoc);
            bIsTransitioningToFollow = false;
        }
        else
        {
            TransitionStartLocation = GetActorLocation(); // captured ONCE, no feedback
            TransitionElapsed = 0.0;
            bIsTransitioningToFollow = true;
        }
    }
    // Left/Right Screen panning
    UFUNCTION()
    void MoveX(float InputAxis)
    {
        if (Math::IsNearlyZero(InputAxis))
            return;

        SetFreeCamera();
        
        float Delta = Gameplay::GetWorldDeltaSeconds();
        float OffsetY = InputAxis * Delta * SpringArm.TargetArmLength * ScrollSpeed;
        
        AddActorWorldOffset(FVector(0, OffsetY, 0));
    }

    // Up/Down Screen panning
    UFUNCTION()
    void MoveY(float InputAxis)
    {
        if (Math::IsNearlyZero(InputAxis))
            return;

        SetFreeCamera();
        
        float Delta = Gameplay::GetWorldDeltaSeconds();
        float OffsetX = InputAxis * Delta * SpringArm.TargetArmLength * ScrollSpeed;
        
        AddActorWorldOffset(FVector(OffsetX, 0, 0));
    }
}