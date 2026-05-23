export async function readJson(
  req: Request
): Promise<Record<string, unknown> | null> {
  try {
    return (await req.json()) as Record<string, unknown>;
  } catch {
    return null;
  }
}

export function badRequest(message: string): Response {
  return Response.json({ error: message }, { status: 400 });
}

export function serverError(message: string): Response {
  return Response.json({ error: message }, { status: 500 });
}
