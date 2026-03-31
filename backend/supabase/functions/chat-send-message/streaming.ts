export interface ChatSSEStreamControls {
  send: (payload: unknown) => boolean;
  close: () => void;
  isClosed: () => boolean;
}

const encoder = new TextEncoder();

export function encodeSSEData(payload: unknown): Uint8Array {
  return encoder.encode(`data: ${JSON.stringify(payload)}\n\n`);
}

export function createChatSSEStream(
  run: (controls: ChatSSEStreamControls) => Promise<void>,
): ReadableStream<Uint8Array> {
  return new ReadableStream({
    start(controller) {
      let closed = false;

      const send = (payload: unknown): boolean => {
        if (closed) return false;
        try {
          controller.enqueue(encodeSSEData(payload));
          return true;
        } catch {
          closed = true;
          return false;
        }
      };

      const close = () => {
        if (closed) return;
        closed = true;
        try {
          controller.close();
        } catch {
          // Ignore disconnect races.
        }
      };

      send({ type: "ready" });

      void (async () => {
        try {
          await run({
            send,
            close,
            isClosed: () => closed,
          });
        } finally {
          close();
        }
      })();
    },
  });
}
