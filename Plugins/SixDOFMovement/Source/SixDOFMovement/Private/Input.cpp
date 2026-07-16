//Copyright 2016-2018 Mookie

#include "SixDOFMovementComponent.h"

float USixDOFMovementComponent::SetForwardInput(float Input) {
	ClientForwardInput = Input;
	if(GetOwner()->GetLocalRole() == ROLE_Authority){
		ForwardInput = Input;
	}

	return Input;
}

float USixDOFMovementComponent::SetRightInput(float Input) {
	ClientRightInput = Input;
	if(GetOwner()->GetLocalRole() == ROLE_Authority){
		RightInput = Input;
	}

	return Input;
}

float USixDOFMovementComponent::SetUpInput(float Input) {
	ClientUpInput = Input;
	if (GetOwner()->GetLocalRole() == ROLE_Authority) {
		UpInput = Input;
	}

	return Input;
}

float USixDOFMovementComponent::SetPitchInput(float Input) {
	ClientPitchInput = Input;
	if (GetOwner()->GetLocalRole() == ROLE_Authority) {
		PitchInput = Input;
	}

	return Input;
}

float USixDOFMovementComponent::SetYawInput(float Input) {
	ClientYawInput = Input;
	if (GetOwner()->GetLocalRole() == ROLE_Authority) {
		YawInput = Input;
	}

	return Input;
}

float USixDOFMovementComponent::SetRollInput(float Input) {
	ClientRollInput = Input;
	if (GetOwner()->GetLocalRole() == ROLE_Authority) {
		RollInput = Input;
	}

	return Input;
}

FVector USixDOFMovementComponent::SetLookAtVector(FVector Input) {
	ClientLookAtVector = Input;
	if (GetOwner()->GetLocalRole() == ROLE_Authority) {
		LookAtVector = Input;
	}

	return Input;
}

FVector USixDOFMovementComponent::SetAutolevelUpVector(FVector Input) {
	ClientAutolevelUpVector = Input;
	if (GetOwner()->GetLocalRole() == ROLE_Authority) {
		AutolevelUpVector = Input;
	}

	return Input;
}

FVector USixDOFMovementComponent::SetMoveToVector(FVector Input) {
	ClientMoveToVector = Input;
	if (GetOwner()->GetLocalRole() == ROLE_Authority) {
		MoveToVector = Input;
	}

	return Input;
}

FRotator USixDOFMovementComponent::SetInputSpaceRotator(FRotator Input) {
	ClientInputSpaceRotator = Input;
	if (GetOwner()->GetLocalRole() == ROLE_Authority) {
		InputSpaceRotator = Input;
	}

	return Input;
}

FVector  USixDOFMovementComponent::RotationInput() const{
	float Pitch;
	float Yaw;
	float Roll;
	FRotator InputSpace;

	if (LocalInputPrediction && GetOwner()->GetLocalRole() == ROLE_AutonomousProxy ) {
		Pitch = ClientPitchInput;
		Yaw = ClientYawInput;
		Roll = ClientRollInput;
		InputSpace = ClientInputSpaceRotator;
	}
	else {
		Pitch=PitchInput;
		Yaw=YawInput;
		Roll=RollInput;
		InputSpace = InputSpaceRotator;
	}

	switch (RotationInputSpace) {
	case(EInputSpace::IS_World):
		return UpdatedComponent->GetComponentQuat().Inverse().RotateVector(FVector(Roll, Pitch, Yaw));
	case(EInputSpace::IS_Actor):
		return (UpdatedComponent->GetComponentQuat().Inverse()*UpdatedComponent->GetOwner()->GetActorRotation().Quaternion()).RotateVector(FVector(Roll, Pitch, Yaw));
	case(EInputSpace::IS_Custom):
		return (UpdatedComponent->GetComponentQuat().Inverse()*InputSpace.Quaternion()).RotateVector(FVector(Roll, Pitch, Yaw));
	default:
		return FVector(Roll, Pitch, Yaw);
	}
}

FVector  USixDOFMovementComponent::TranslationInput() const{
	float Forward;
	float Up;
	float Right;
	FRotator InputSpace;

	if (LocalInputPrediction && GetOwner()->GetLocalRole() == ROLE_AutonomousProxy) {
		Forward = ClientForwardInput;
		Up = ClientUpInput;
		Right = ClientRightInput;
		InputSpace = ClientInputSpaceRotator;
	}
	else {
		Forward = ForwardInput;
		Up = UpInput;
		Right = RightInput;
		InputSpace = InputSpaceRotator;
	}

	switch (TranslationInputSpace) {
	case(EInputSpace::IS_World):
		return UpdatedComponent->GetComponentQuat().Inverse().RotateVector(FVector(Forward, Right, Up));
	case(EInputSpace::IS_Actor):
		return (UpdatedComponent->GetComponentQuat().Inverse()*UpdatedComponent->GetOwner()->GetActorRotation().Quaternion()).RotateVector(FVector(Forward, Right, Up));
	case(EInputSpace::IS_Custom):
		return (UpdatedComponent->GetComponentQuat().Inverse()*InputSpace.Quaternion()).RotateVector(FVector(Forward, Right, Up));
	default:
		return FVector(ForwardInput, RightInput, UpInput);
	}
}