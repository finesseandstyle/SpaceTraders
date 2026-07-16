//Copyright 2016-2020 Mookie

#include "SixDOFMovementComponent.h"

FVector USixDOFMovementComponent::AutopilotRotation(const FVector &Location, const FQuat &Rotation) const {
	FVector Input = RotationInput();
	FVector LookAtOutput = FVector(0, 0, 0);
	FVector LevelOutput = FVector(0, 0, 0);
	FVector DampOutput = FVector(0, 0, 0);

	FVector Look;
	FVector Level;

	if (LocalInputPrediction && GetOwner()->GetLocalRole() == ROLE_AutonomousProxy) {
		Look = ClientLookAtVector;
		Level = ClientAutolevelUpVector;
	}
	else {
		Look = LookAtVector;
		Level = AutolevelUpVector;
	}

	if (LookAt) {
		FVector LookAtGoal;
		switch (LookAtMode) {

			case(EAutopilotMode::LM_Direction): {
				LookAtGoal = Look.GetSafeNormal();
				break;
			}

			case(EAutopilotMode::LM_Controller): {
				if (PawnOwner) {
					LookAtGoal = PawnOwner->GetControlRotation().Quaternion().GetForwardVector();
				}
				else {
					UE_LOG(LogTemp, Warning, TEXT("using LM_Controller with non-pawn actor"));
					LookAtGoal = FVector(0, 0, 0);
				}
				break;
			}

			case(EAutopilotMode::LM_Location): {
				LookAtGoal = (Look - Location).GetSafeNormal();
				break;
			}

			default:{
				UE_LOG(LogTemp, Warning, TEXT("invalid autopilot rotation mode"));
			}

		}

		LookAtOutput = AutopilotLookAt(Rotation, LookAtGoal);
	}

	if (Autolevel) {
		LevelOutput = AutopilotAutolevel(Rotation, AutolevelUpVector);
	}

	if (RotationDamping) {
		DampOutput = AutopilotRotationDamping(Rotation, AngularVelocity);
	}
	
	return BlendInput(LookAtOutput+LevelOutput+DampOutput,Input);
}

FVector USixDOFMovementComponent::AutopilotTranslation(const FVector &Location, const FQuat &Rotation) const {
	FVector Input = TranslationInput();
	FVector MoveToOutput = FVector(0, 0, 0);
	FVector DampOutput = FVector(0, 0, 0);

	FVector Move;

	if (LocalInputPrediction && GetOwner()->GetLocalRole() == ROLE_AutonomousProxy) {
		Move = ClientMoveToVector;
	}
	else {
		Move = MoveToVector;
	}

	if (MoveTo) {
		FVector MoveToGoal;
		switch (MoveToMode) {
			case(EAutopilotMode::LM_Direction): {
				MoveToGoal = Move;
				break;
			}

			case(EAutopilotMode::LM_Controller): {
				if (PawnOwner) {
					MoveToGoal = PawnOwner->ConsumeMovementInputVector();
				}
				else {
					UE_LOG(LogTemp, Warning, TEXT("using LM_Controller with non-pawn actor"));
					MoveToGoal = FVector(0, 0, 0);
				}
				break;
			}

			case(EAutopilotMode::LM_Location): {
				MoveToGoal = (Move - Location);
				break;
			}

			default: {
				UE_LOG(LogTemp, Warning, TEXT("invalid autopilot translation mode"));
			}
		}

		float FwdDot = FVector::DotProduct(Rotation.GetForwardVector(), MoveToGoal);
		float RightDot = FVector::DotProduct(Rotation.GetRightVector(), MoveToGoal);
		float UpDot = FVector::DotProduct(Rotation.GetUpVector(), MoveToGoal);

		MoveToOutput = FVector(FwdDot, RightDot, UpDot);
		MoveToOutput = MoveToOutput*FVector(MoveToSensitivityForward, MoveToSensitivityRight, MoveToSensitivityUp);
	}

	if(TranslationDamping) {
		DampOutput = AutopilotTranslationDamping(Rotation, Velocity);
	}

	return BlendInput(MoveToOutput+DampOutput, Input);
}
