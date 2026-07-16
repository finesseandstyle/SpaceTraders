//Copyright 2016-2023 Mookie

#include "SixDOFMovementComponent.h"
#include "Kismet/GameplayStatics.h"
#include "Net/UnrealNetwork.h"
#include "GameFramework/PlayerState.h"

void USixDOFMovementComponent::GetLifetimeReplicatedProps(TArray< FLifetimeProperty > & OutLifetimeProps) const {
	Super::GetLifetimeReplicatedProps(OutLifetimeProps);

	DOREPLIFETIME_CONDITION(USixDOFMovementComponent, PitchInput, COND_Custom);
	DOREPLIFETIME_CONDITION(USixDOFMovementComponent, YawInput, COND_Custom);
	DOREPLIFETIME_CONDITION(USixDOFMovementComponent, RollInput, COND_Custom);

	DOREPLIFETIME_CONDITION(USixDOFMovementComponent, ForwardInput, COND_Custom);
	DOREPLIFETIME_CONDITION(USixDOFMovementComponent, RightInput, COND_Custom);
	DOREPLIFETIME_CONDITION(USixDOFMovementComponent, UpInput, COND_Custom);

	DOREPLIFETIME_CONDITION(USixDOFMovementComponent, LookAtVector, COND_Custom);
	DOREPLIFETIME_CONDITION(USixDOFMovementComponent, AutolevelUpVector, COND_Custom);
	DOREPLIFETIME_CONDITION(USixDOFMovementComponent, MoveToVector, COND_Custom);
	DOREPLIFETIME_CONDITION(USixDOFMovementComponent, InputSpaceRotator, COND_Custom);

	DOREPLIFETIME(USixDOFMovementComponent, ClientAuthoritativeMovement);
}

void USixDOFMovementComponent::PreReplication(IRepChangedPropertyTracker& ChangedPropertyTracker) {
	Super::PreReplication(ChangedPropertyTracker);

	DOREPLIFETIME_ACTIVE_OVERRIDE(USixDOFMovementComponent, PitchInput, ReplicateInputs);
	DOREPLIFETIME_ACTIVE_OVERRIDE(USixDOFMovementComponent, YawInput, ReplicateInputs);
	DOREPLIFETIME_ACTIVE_OVERRIDE(USixDOFMovementComponent, RollInput, ReplicateInputs);

	DOREPLIFETIME_ACTIVE_OVERRIDE(USixDOFMovementComponent, ForwardInput, ReplicateInputs);
	DOREPLIFETIME_ACTIVE_OVERRIDE(USixDOFMovementComponent, RightInput, ReplicateInputs);
	DOREPLIFETIME_ACTIVE_OVERRIDE(USixDOFMovementComponent, UpInput, ReplicateInputs);

	DOREPLIFETIME_ACTIVE_OVERRIDE(USixDOFMovementComponent, LookAtVector, ReplicateInputs);
	DOREPLIFETIME_ACTIVE_OVERRIDE(USixDOFMovementComponent, AutolevelUpVector, ReplicateInputs);
	DOREPLIFETIME_ACTIVE_OVERRIDE(USixDOFMovementComponent, MoveToVector, ReplicateInputs);
	DOREPLIFETIME_ACTIVE_OVERRIDE(USixDOFMovementComponent, InputSpaceRotator, ReplicateInputs);
}

void USixDOFMovementComponent::BroadcastMovement(float DeltaTime) {
	if (GetOwner()->GetLocalRole() != ROLE_Authority) return;
	if (!ReplicateMovement) return;
	if (MovementReplicationFrequency <= 0.0f) return; //do not replicate if frequency is 0

	//sleep stationary
	if (PauseReplicationWhenStationary) {
		UpdateStationarySleepTimer(DeltaTime);

		if (TimeSinceMovement > StationaryTimeToSleep) {
			return;
		}
	}

	if (TimeSincePositionBroadcast >= 1.0f / MovementReplicationFrequency) {
		TimeSincePositionBroadcast = 0.0f;

		FVector Location = GetOwner()->GetActorLocation();
		Location = UGameplayStatics::RebaseLocalOriginOntoZero(GetWorld(), Location);
		MovementRep(Location, GetOwner()->GetActorRotation(), Velocity, AngularVelocity);
	}

	TimeSincePositionBroadcast += DeltaTime;
}

void USixDOFMovementComponent::BroadcastClientMovement(float DeltaTime) {
	if (GetOwner()->GetLocalRole() != ROLE_AutonomousProxy) return;
	if (!GetPawnOwner()->IsLocallyControlled()) return;
	if (!ReplicateMovement) return;
	if (!ClientAuthoritativeMovement) return;
	if (ClientMovementReplicationFrequency <= 0.0f) return; //do not replicate if frequency is 0

	if (TimeSinceClientPositionBroadcast >= 1.0f / ClientMovementReplicationFrequency) {
		TimeSinceClientPositionBroadcast = 0.0f;

		FVector Location = GetOwner()->GetActorLocation();
		Location = UGameplayStatics::RebaseLocalOriginOntoZero(GetWorld(), Location);
		ClientMovementRep(Location, GetOwner()->GetActorRotation(), Velocity, AngularVelocity);
	}

	TimeSinceClientPositionBroadcast += DeltaTime;
}

void USixDOFMovementComponent::BroadcastInput(float DeltaTime) {
	if (GetOwner()->GetLocalRole() != ROLE_AutonomousProxy) return;
	if (!GetPawnOwner()->IsLocallyControlled()) return;

	if (!ReplicateInputs) return;
	if (InputReplicationFrequency <= 0.0f) return; //do not replicate if frequency is 0

	if (TimeSinceInputBroadcast >= 1.0f / InputReplicationFrequency) {

		if ((ClientForwardInput != ForwardInput) ||
		(ClientRightInput != RightInput) ||
		(ClientUpInput != UpInput) ||
		(ClientPitchInput != PitchInput) ||
		(ClientYawInput != YawInput) ||
		(ClientRollInput != RollInput)) {
			TimeSinceInputBroadcast = 0.0f;
			InputRep(FVector(ClientForwardInput, ClientRightInput, ClientUpInput), FVector(ClientPitchInput, ClientYawInput, ClientRollInput));
		}

		if ((ClientLookAtVector != LookAtVector) ||
		(ClientMoveToVector != MoveToVector)){
			TimeSinceInputBroadcast = 0.0f;

			FVector MoveToVec = ClientMoveToVector;

			if (MoveToMode == EAutopilotMode::LM_Location) {
				MoveToVec = UGameplayStatics::RebaseLocalOriginOntoZero(GetWorld(), MoveToVec);
			}

			GoalRep(ClientLookAtVector, MoveToVec);
		}

		if (ClientAutolevelUpVector != AutolevelUpVector) {
			TimeSinceInputBroadcast = 0.0f;
			UpVecRep(ClientAutolevelUpVector);
		}

		if (ClientInputSpaceRotator != InputSpaceRotator){
			TimeSinceInputBroadcast = 0.0f;
			InputSpaceRep(ClientInputSpaceRotator);
		}

	}

	TimeSinceInputBroadcast += DeltaTime;
}

void USixDOFMovementComponent::UpdateStationarySleepTimer(float DeltaTime) {
	FVector Location = GetOwner()->GetActorLocation();
	FRotator Rotation = GetOwner()->GetActorRotation();

	if (((Location - PreviousLocation).Size()>StationarySleepMaxDistance) || 
		(FMath::Abs(Rotation.Pitch - PreviousRotation.Pitch)>StationarySleepMaxAngle ) ||
		(FMath::Abs(Rotation.Yaw - PreviousRotation.Yaw)>StationarySleepMaxAngle) ||
		(FMath::Abs(Rotation.Roll - PreviousRotation.Roll)>StationarySleepMaxAngle)
		) {
		TimeSinceMovement = 0;
		PreviousLocation = Location;
		PreviousRotation = Rotation;
	}
	else {
		TimeSinceMovement += DeltaTime;
	}
}

void USixDOFMovementComponent::MovementRep_Implementation(FVector NewLocation, FRotator NewRotation, FVector NewVelocity, FVector NewAngularVelocity) {
	AActor* Owner = GetOwner();
	if (!IsValid(Owner)) return;
	if ((ClientAuthoritativeMovement) && (Owner->GetLocalRole() == ROLE_AutonomousProxy)) return;


	if (Owner->GetLocalRole() != ROLE_Authority) {
		NewLocation=UGameplayStatics::RebaseZeroOriginOntoLocal(GetWorld(), NewLocation); //change for 413

		if ((NewLocation - Owner->GetActorLocation()).SizeSquared() >= FMath::Pow(MovementReplicationTeleportThreshold, 2.0f)) {
			SetPositionAndVelocity(NewLocation, NewRotation, NewVelocity, NewAngularVelocity);
		}
		else {
			SetPositionAndVelocitySoft(NewLocation, NewRotation, NewVelocity, NewAngularVelocity);
		}
	}
}

void USixDOFMovementComponent::SetPositionAndVelocity(FVector NewLocation, FRotator NewRotation, FVector NewVelocity, FVector NewAngularVelocity) {
	AActor* Owner = GetOwner();

	Owner->SetActorLocationAndRotation(NewLocation, NewRotation, false, NULL, ETeleportType::TeleportPhysics);
	Velocity = NewVelocity;
	AngularVelocity = NewAngularVelocity;

	if (IsValid(UpdatedPrimitive)) {
		if (UpdatedPrimitive->IsSimulatingPhysics()) {
			UpdatedPrimitive->SetPhysicsLinearVelocity(NewVelocity);
			UpdatedPrimitive->SetPhysicsAngularVelocityInDegrees(NewAngularVelocity);
		}
	}

	LocationError = FVector(0, 0, 0);
	VelocityError = FVector(0, 0, 0);
	AngularVelocityError = FVector(0, 0, 0);
	RotationError = FQuat::Identity;
}

void USixDOFMovementComponent::SetPositionAndVelocitySoft(FVector NewLocation, FRotator NewRotation, FVector NewVelocity, FVector NewAngularVelocity) {
	AActor* Owner = GetOwner();

	//Latency compensation
	if (LatencyCompensation) {
		APlayerController* Controller = GetWorld()->GetFirstPlayerController();
		if(Controller){
			if(Controller->PlayerState){
			float Ping = Controller->PlayerState->ExactPing*0.001;
				if (Ping > 0.001) {
					NewLocation += NewVelocity * Ping;
					FQuat LagCompDelta = FQuat(NewAngularVelocity, Ping * PI / 180.0f);

					NewRotation = (LagCompDelta*NewRotation.Quaternion()).Rotator();
				}
			}
		}
	}

	LocationError = NewLocation - Owner->GetActorLocation();
	VelocityError = NewVelocity - Velocity;
	AngularVelocityError = NewAngularVelocity - AngularVelocity;

	RotationError = FQuat(NewRotation.Quaternion()*Owner->GetActorRotation().Quaternion().Inverse());
}

void USixDOFMovementComponent::ErrorCatchUp(float DeltaTime) {
	if (!ReplicateMovement) return;
	AActor* Owner = GetOwner();

	float ErrorDeltaLateral = FMath::Min(DeltaTime / MovementReplicationSmoothingLocation, 1.0f);
	float ErrorDeltaForward = FMath::Min(DeltaTime / (MovementReplicationSmoothingLocation + MovementReplicationAntiJitter), 1.0f);
	float ErrorDeltaRot = FMath::Min(DeltaTime / MovementReplicationSmoothingRotation, 1.0f);
	
	//CalculateForwardDirection
	FVector MovementDirection=Velocity.GetSafeNormal();
	if (IsValid(UpdatedPrimitive)) {
		if (UpdatedPrimitive->IsSimulatingPhysics()) {
			MovementDirection=(UpdatedPrimitive->GetPhysicsLinearVelocity()).GetSafeNormal();
		}
	}


	FVector LocationErrorForward = FVector::DotProduct(LocationError, MovementDirection)*MovementDirection;
	FVector LocationErrorLateral = LocationError - LocationErrorForward;

	FVector LocationCorrection = (LocationErrorLateral * ErrorDeltaLateral) + (LocationErrorForward*ErrorDeltaForward);

	Owner->SetActorLocation(Owner->GetActorLocation() + LocationCorrection,false,NULL,ETeleportType::TeleportPhysics);
	Velocity += VelocityError*ErrorDeltaLateral;
	AngularVelocity += AngularVelocityError*ErrorDeltaRot;

	Owner->SetActorRotation(FQuat::Slerp(Owner->GetActorRotation().Quaternion(), RotationError*Owner->GetActorRotation().Quaternion(),ErrorDeltaRot), ETeleportType::TeleportPhysics);

	if (IsValid(UpdatedPrimitive)){
		if(UpdatedPrimitive->IsSimulatingPhysics()) {
			UpdatedPrimitive->SetPhysicsLinearVelocity(VelocityError*ErrorDeltaLateral,true);
			UpdatedPrimitive->SetPhysicsAngularVelocityInDegrees(AngularVelocityError*ErrorDeltaRot, true);
		}
	}

	LocationError -= LocationCorrection;
	VelocityError *= 1.0f - ErrorDeltaLateral;
	AngularVelocityError *= 1.0f - ErrorDeltaRot;
	RotationError = FQuat::Slerp(RotationError, FQuat::Identity,ErrorDeltaRot);
}

void USixDOFMovementComponent::InputRep_Implementation(FVector TranslationInput, FVector RotationInput) {
	ForwardInput = TranslationInput.X;
	RightInput = TranslationInput.Y;
	UpInput = TranslationInput.Z;

	PitchInput = RotationInput.X;
	YawInput = RotationInput.Y;
	RollInput = RotationInput.Z;
}


bool USixDOFMovementComponent::InputRep_Validate(FVector TranslationInput, FVector RotationInput) {
	return true;
}

void USixDOFMovementComponent::GoalRep_Implementation(FVector LookAtGoal, FVector MoveToGoal) {
	LookAtVector = LookAtGoal;  
//change for 413, all below to this line:  MoveToVector = MoveToGoal;
	if (MoveToMode == EAutopilotMode::LM_Location) {
		MoveToVector = UGameplayStatics::RebaseZeroOriginOntoLocal(GetWorld(),MoveToGoal);
	}
	else {
		MoveToVector = MoveToGoal;
	}
//end change for 413
}
bool USixDOFMovementComponent::GoalRep_Validate(FVector LookAtGoal, FVector MoveToGoal) {
	return true;
}

void USixDOFMovementComponent::UpVecRep_Implementation(FVector LevelGoal) {
	AutolevelUpVector = LevelGoal;
}
bool USixDOFMovementComponent::UpVecRep_Validate(FVector LevelGoal) {
	return true;
}

void USixDOFMovementComponent::InputSpaceRep_Implementation(FRotator InputRotator) {
	InputSpaceRotator = InputRotator;
}
bool USixDOFMovementComponent::InputSpaceRep_Validate(FRotator InputRotator) {
	return true;
}

void USixDOFMovementComponent::ClientMovementRep_Implementation(FVector NewLocation, FRotator NewRotation, FVector NewVelocity, FVector NewAngularVelocity) {
	if (!ClientAuthoritativeMovement) return;
	AActor* Owner = GetOwner();

	SetPositionAndVelocity(NewLocation, NewRotation, NewVelocity, NewAngularVelocity);
}

bool USixDOFMovementComponent::ClientMovementRep_Validate(FVector NewLocation, FRotator NewRotation, FVector NewVelocity, FVector NewAngularVelocity) {
	return true;
}