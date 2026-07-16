// Copyright 1998-2016 Epic Games, Inc. All Rights Reserved.
using UnrealBuildTool;
using System.IO;

namespace UnrealBuildTool.Rules
{
        public class SixDOFMovement : ModuleRules
    {
        public SixDOFMovement(ReadOnlyTargetRules Target) : base(Target)
        {
            PCHUsage = ModuleRules.PCHUsageMode.UseExplicitOrSharedPCHs;
            DefaultBuildSettings = BuildSettingsVersion.Latest;
            IncludeOrderVersion = EngineIncludeOrderVersion.Latest;

            PublicIncludePaths.Add(
                     Path.Combine(ModuleDirectory,"Public")
                );


            PrivateIncludePaths.Add(
                     Path.Combine(ModuleDirectory,"Private")
                );


            PublicDependencyModuleNames.AddRange(
                new string[]
                {
                    "Core",
                    "CoreUObject",
                    "Engine",
                    "NetCore"
			    }
                );
        }
    }
}
