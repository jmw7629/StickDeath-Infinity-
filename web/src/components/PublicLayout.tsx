import { Outlet, useLocation } from "react-router-dom";
import { Header } from "./Header";

export function PublicLayout() {
  const location = useLocation();
  // Landing page has its own nav built-in
  const isLanding = location.pathname === "/";

  return (
    <div className="min-h-screen flex flex-col">
      {!isLanding && <Header />}
      <main className={`flex-1 flex flex-col ${!isLanding ? "pt-14" : ""}`}>
        <Outlet />
      </main>
    </div>
  );
}
