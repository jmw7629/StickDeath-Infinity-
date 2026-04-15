import {
  LayoutDashboard,
  PenTool,
  Rss,
  Trophy,
  Settings,
  LogOut,
  Skull,
} from "lucide-react";
import { useNavigate, useLocation } from "react-router-dom";
import { useAuthActions } from "@convex-dev/auth/react";
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarGroup,
  SidebarGroupContent,
  SidebarHeader,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
} from "@/components/ui/sidebar";

const mainNav = [
  { title: "Dashboard", icon: LayoutDashboard, path: "/dashboard" },
  { title: "Studio", icon: PenTool, path: "/studio" },
  { title: "Feed", icon: Rss, path: "/feed" },
  { title: "Challenges", icon: Trophy, path: "/challenges" },
];

const bottomNav = [
  { title: "Settings", icon: Settings, path: "/settings" },
];

export function AppSidebar() {
  const navigate = useNavigate();
  const location = useLocation();
  const { signOut } = useAuthActions();

  return (
    <Sidebar collapsible="icon">
      <SidebarHeader className="border-b border-sidebar-border">
        <div
          className="flex items-center gap-2 px-2 py-1 cursor-pointer"
          onClick={() => navigate("/dashboard")}
        >
          <div className="w-8 h-8 rounded-lg bg-red-600 flex items-center justify-center">
            <Skull size={18} className="text-white" />
          </div>
          <div className="flex flex-col group-data-[collapsible=icon]:hidden">
            <span className="text-xs font-black">
              <span className="text-red-600">STICK</span>
              <span className="text-foreground">DEATH</span>
            </span>
            <span className="text-[9px] text-muted-foreground -mt-0.5">INFINITY</span>
          </div>
        </div>
      </SidebarHeader>

      <SidebarContent>
        <SidebarGroup>
          <SidebarGroupContent>
            <SidebarMenu>
              {mainNav.map((item) => (
                <SidebarMenuItem key={item.title}>
                  <SidebarMenuButton
                    isActive={location.pathname === item.path}
                    onClick={() => navigate(item.path)}
                    tooltip={item.title}
                  >
                    <item.icon />
                    <span>{item.title}</span>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              ))}
            </SidebarMenu>
          </SidebarGroupContent>
        </SidebarGroup>
      </SidebarContent>

      <SidebarFooter>
        <SidebarMenu>
          {bottomNav.map((item) => (
            <SidebarMenuItem key={item.title}>
              <SidebarMenuButton
                isActive={location.pathname === item.path}
                onClick={() => navigate(item.path)}
                tooltip={item.title}
              >
                <item.icon />
                <span>{item.title}</span>
              </SidebarMenuButton>
            </SidebarMenuItem>
          ))}
          <SidebarMenuItem>
            <SidebarMenuButton
              onClick={() => void signOut().then(() => navigate("/"))}
              tooltip="Sign Out"
            >
              <LogOut />
              <span>Sign Out</span>
            </SidebarMenuButton>
          </SidebarMenuItem>
        </SidebarMenu>
      </SidebarFooter>
    </Sidebar>
  );
}
