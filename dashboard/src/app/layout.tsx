import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Backup Tool",
  description: "MariaDB & Podman Backup Dashboard",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className="dark" suppressHydrationWarning>
      <body>{children}</body>
    </html>
  );
}
