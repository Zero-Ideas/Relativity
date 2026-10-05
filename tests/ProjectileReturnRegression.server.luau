-- Private-network Studio harness; does not alter the live projectile registry.
local Projectile=require(script.Parent.Projectile)
local player=game.Players:GetPlayers()[1]
local origin=player.Character.PrimaryPart.Position+Vector3.yAxis*240
local wall=Instance.new("Part")
wall.Name="_ProjectileReturnWall"
wall.Anchored=true
wall.Transparency=1
wall.Size=Vector3.new(2,20,20)
wall.Position=origin+Vector3.xAxis*600
wall.Parent=workspace
local p=Projectile.new({Origin=origin,Direction=Vector3.xAxis,Speed=1000,
	Lifetime=2,Radius=.2,Bounces=1,Restitution=1,VisualRange=300,Visualize=true})
script:SetAttribute("Id",p.Id)
p.OnBounce=function() script:SetAttribute("Bounced",true) end
task.wait(1.1)
script:SetAttribute("Returned",p.Position.X<origin.X+200 and p.Velocity.X<0 and not p.Dead)
task.wait(.05)
p:Destroy()
wall:Destroy()
script:SetAttribute("Complete",true)
