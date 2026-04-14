export const getNodeErrorCode = (error: unknown): string | null => {
  if (typeof error !== "object" || error === null || !("code" in error)) {
    return null;
  }

  const code = (error as { readonly code?: unknown }).code;
  return typeof code === "string" ? code : null;
};