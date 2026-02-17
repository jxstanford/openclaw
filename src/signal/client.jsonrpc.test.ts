import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { WebSocketServer } from "ws";
import {
	detectSignalApiMode,
	type SignalSseEvent,
	streamSignalJsonRpc,
} from "./client.js";

// ---------- detectSignalApiMode tests (mock fetch) ----------

const fetchMock = vi.fn();
vi.mock("../infra/fetch.js", () => ({
	resolveFetch: () => fetchMock,
}));

describe("detectSignalApiMode", () => {
	beforeEach(() => {
		fetchMock.mockReset();
	});

	it('returns "sse" when /api/v1/events responds 200', async () => {
		fetchMock.mockResolvedValueOnce({
			ok: true,
			body: { cancel: vi.fn() },
		});
		const mode = await detectSignalApiMode("http://localhost:8080");
		expect(mode).toBe("sse");
	});

	it('returns "jsonrpc" when /api/v1/events responds 404', async () => {
		fetchMock.mockResolvedValueOnce({
			ok: false,
			status: 404,
			body: null,
		});
		const mode = await detectSignalApiMode("http://localhost:8080");
		expect(mode).toBe("jsonrpc");
	});

	it('returns "jsonrpc" when fetch throws (connection refused)', async () => {
		fetchMock.mockRejectedValueOnce(new Error("ECONNREFUSED"));
		const mode = await detectSignalApiMode("http://localhost:8080");
		expect(mode).toBe("jsonrpc");
	});
});

// ---------- streamSignalJsonRpc tests (real WebSocket server) ----------

describe("streamSignalJsonRpc", () => {
	let wss: WebSocketServer;
	let port: number;

	beforeEach(async () => {
		wss = new WebSocketServer({ port: 0 });
		const addr = wss.address();
		port = typeof addr === "object" && addr ? addr.port : 0;
	});

	afterEach(() => {
		wss.close();
	});

	it("converts JSON-RPC receive notifications to SignalSseEvent", async () => {
		const events: SignalSseEvent[] = [];

		wss.on("connection", (ws) => {
			ws.send(
				JSON.stringify({
					jsonrpc: "2.0",
					method: "receive",
					params: {
						envelope: {
							sourceNumber: "+15550001111",
							dataMessage: { message: "hello" },
						},
					},
				}),
			);
			// Close after sending so the stream ends
			setTimeout(() => ws.close(), 50);
		});

		await streamSignalJsonRpc({
			baseUrl: `http://127.0.0.1:${port}`,
			onEvent: (event) => events.push(event),
		});

		expect(events).toHaveLength(1);
		expect(events[0].event).toBe("receive");
		const data = JSON.parse(events[0].data!);
		expect(data.envelope.sourceNumber).toBe("+15550001111");
		expect(data.envelope.dataMessage.message).toBe("hello");
	});

	it("ignores non-receive JSON-RPC messages", async () => {
		const events: SignalSseEvent[] = [];

		wss.on("connection", (ws) => {
			// A response to a request (has id, no method)
			ws.send(
				JSON.stringify({
					jsonrpc: "2.0",
					result: { version: "0.13" },
					id: "1",
				}),
			);
			// A different method
			ws.send(
				JSON.stringify({ jsonrpc: "2.0", method: "version", params: {} }),
			);
			setTimeout(() => ws.close(), 50);
		});

		await streamSignalJsonRpc({
			baseUrl: `http://127.0.0.1:${port}`,
			onEvent: (event) => events.push(event),
		});

		expect(events).toHaveLength(0);
	});

	it("resolves when server closes connection", async () => {
		wss.on("connection", (ws) => {
			ws.close();
		});

		await expect(
			streamSignalJsonRpc({
				baseUrl: `http://127.0.0.1:${port}`,
				onEvent: () => {},
			}),
		).resolves.toBeUndefined();
	});

	it("resolves immediately when abortSignal is already aborted", async () => {
		const controller = new AbortController();
		controller.abort();

		await expect(
			streamSignalJsonRpc({
				baseUrl: `http://127.0.0.1:${port}`,
				abortSignal: controller.signal,
				onEvent: () => {},
			}),
		).resolves.toBeUndefined();
	});
});
