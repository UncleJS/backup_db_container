"use server";

import { redirect } from "next/navigation";
import { createSession, deleteSession } from "@/lib/session";
import { readFileSync } from "fs";
import bcrypt from "bcryptjs";

function getAdminPassword(): string {
  // Try Podman secret first, then env
  try {
    return readFileSync("/run/secrets/dashboard_admin_password", "utf-8").trim();
  } catch {
    return process.env.DASHBOARD_ADMIN_PASSWORD ?? "";
  }
}

function getAdminUsername(): string {
  return process.env.DASHBOARD_ADMIN_USER ?? "admin";
}

export async function loginAction(
  _prevState: { error?: string } | null,
  formData: FormData
): Promise<{ error: string } | null> {
  const username = formData.get("username") as string;
  const password = formData.get("password") as string;

  if (!username || !password) {
    return { error: "Username and password are required." };
  }

  const adminUser = getAdminUsername();
  const storedPassword = getAdminPassword();

  if (!storedPassword) {
    return { error: "Admin password not configured. Check your secrets setup." };
  }

  const usernameMatch = username === adminUser;
  // Support both bcrypt hashed and plain passwords
  let passwordMatch = false;
  if (storedPassword.startsWith("$2b$") || storedPassword.startsWith("$2a$")) {
    passwordMatch = await bcrypt.compare(password, storedPassword);
  } else {
    passwordMatch = password === storedPassword;
  }

  if (!usernameMatch || !passwordMatch) {
    return { error: "Invalid username or password." };
  }

  await createSession(username, username);
  redirect("/");
}

export async function logoutAction() {
  await deleteSession();
  redirect("/login");
}
