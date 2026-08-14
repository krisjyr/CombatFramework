# Other
- *MAJOR* Cannot swim downwards/upwards
- *MAJOR* Slope/stair detection still mediocre and half/working
- *MAJOR* Something breaks stances and everything on movement. Possibly slope/stair detection?
- *MAJOR* Climb stance not activating while climbing Trusses, or ladders.
- *MAJOR* While swimming, activates jump stance.
- *MAJOR* Missing falling/landing(from falling) stance which could be added animations to
- *To-Add* Rotation of body to stances (So crawl can be made into the character in actual crawl position with chest on the ground)

### Inverse Kinematics
- **MAJOR FIXXXXEEDD!!!!** On crouch the IK rotates the front leg 180 degrees (left side of the leg is on the right and right side is on the left), but the leg position stays correct. Same happens while walking, it for some reason jitters/rotates 180 and then back to normal. Same is happening while strafing, while moving overall. ( ROBLOX's OWN FUCKING ENGINE ISSUE, NONFIXABLE IF DONT FULL REWRITE TO CUSTOM ENGINE) **[NEVER FUCKIN MINDDD. GOT IT FIXED BY MAKING A RIG WITH CONSTRAINTSSSS!!!]**
- *MAJOR* Arm IK that looks natural while walking (Currently wrists not moving at all)
- *MEDIUM* Modify IK values for better stance procedural anims. (Currently running is trash)
- *To-Add* Step sounds based on material

### Animations
- *MAJOR* Animation engine swap and smoothness between animations is slow and doesn't instantly default to standing idle.


### Camera
- *MAJOR* Set lean camera based on how far character leans
- *MAJOR* Lean camera + freelook camera mess eachother up.
- *MAJOR* Camera should move with head when torso, etc is tilting
- *MAJOR* The camera tilt effect when turning is jittery. It should be smooth when turning and stopping. Additionally when i turn and stop then it takes a few seconds before it chooses to return to the original position instead of smoothly returning immediately
- *MEDIUM* When zooming into first person, camera goes to where it last was not where cam is looking.
- *MEDIUM* Freelook should return camera back to where body is facing, not body to where the camera is facing
- *MEDIUM* Camera starts freaking out (CFrame values rising to unreal amounts) after a bit of time when studio / game is out of focus.
*MEDIUM* Strafing effects not working well in firstperson (Probably due to movement and camera engines conflicting a little somehow)
- *LOW* Remove strafing effects from third-person cam. Even better: Add configs for effects of which is on/off in thirdperson/firstperson
- *LOW* When in first-person character's shadow's head is missing (probably due to head transparency in FP).

### Character Effects (Looking around, etc)
- **DONE**

### Ragdoll
*CRITICAL* Ragdoll broken / not ragdolling on death
*To-Add* Ragdoll stays a set time on death
*Future* Ragdoll draggable via interaction system (Depending on which bodypart is interacted with or chosen through interaction popup). Characters will have a weight aswell, the heavier they are the harder to drag (weight also depends on gravity). I will also have a strength stats added so the stronger you are the easier to drag (for example if in exosuit)

### Falling
- *MAJOR* Fall effects (Air sounds, Impact sounds, Camera Shake) not activating