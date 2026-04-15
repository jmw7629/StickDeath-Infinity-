import { Navigate, Route, Routes, useLocation } from "react-router-dom";
import { AppLayout } from "./components/AppLayout";
import ErrorBoundary from "./components/ErrorBoundary";
import { ProtectedRoute } from "./components/ProtectedRoute";
import { PublicLayout } from "./components/PublicLayout";
import { PublicOnlyRoute } from "./components/PublicOnlyRoute";
import SpatterOverlay from "./components/SpatterOverlay";
import { Toaster } from "./components/ui/sonner";
import { ThemeProvider } from "./contexts/ThemeContext";
import {
  DashboardPage,
  LandingPage,
  LoginPage,
  SettingsPage,
  SignupPage,
  StudioPage,
  HomePage,
  StudioHubPage,
  ChallengesPage,
  ProfilePage,
  SpatterPage,
} from "./pages";

// Spatter overlay shows on all app screens except landing/auth and the editor
function SpatterGlobal() {
  const location = useLocation();
  const hideSpatter = ["/", "/login", "/signup"].includes(location.pathname)
    || location.pathname.startsWith("/studio/project");
  if (hideSpatter) return null;
  return <SpatterOverlay />;
}

function App() {
  return (
    <ErrorBoundary>
      <ThemeProvider defaultTheme="dark" switchable={false}>
        <Toaster />

        {/* Global Spatter overlay — always available except on public/editor pages */}
        <SpatterGlobal />

        <Routes>
          <Route element={<PublicLayout />}>
            <Route path="/" element={<LandingPage />} />
            <Route element={<PublicOnlyRoute />}>
              <Route path="/login" element={<LoginPage />} />
              <Route path="/signup" element={<SignupPage />} />
            </Route>
          </Route>

          {/* App screens with bottom nav */}
          <Route path="/home" element={<HomePage />} />
          <Route path="/challenges" element={<ChallengesPage />} />
          <Route path="/studio" element={<StudioHubPage />} />
          <Route path="/profile" element={<ProfilePage />} />
          <Route path="/spatter" element={<SpatterPage />} />

          <Route element={<ProtectedRoute />}>
            {/* Editor is full-screen, no bottom nav, no Spatter overlay (has its own panel) */}
            <Route path="/studio/project/new" element={<StudioPage />} />
            <Route path="/studio/project/:projectId" element={<StudioPage />} />

            <Route element={<AppLayout />}>
              <Route path="/dashboard" element={<DashboardPage />} />
              <Route path="/settings" element={<SettingsPage />} />
            </Route>
          </Route>

          {/* Legacy redirect */}
          <Route path="/feed" element={<Navigate to="/home" replace />} />

          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </ThemeProvider>
    </ErrorBoundary>
  );
}

export default App;
