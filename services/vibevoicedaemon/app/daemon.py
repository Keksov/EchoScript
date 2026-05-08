import asyncio
import json
import logging
import uuid
from typing import Any

import websockets
import websockets.exceptions

from .model import VibevoiceModel
from .session import Session

LOGGER = logging.getLogger(__name__)


async def _handle_connection(websocket: Any, model: VibevoiceModel) -> None:
    connection_id = str(uuid.uuid4())
    session = Session(model, connection_id)
    LOGGER.info("Connection opened %s from %s", connection_id, websocket.remote_address)
    try:
        async for message in websocket:
            if isinstance(message, bytes):
                reply = await session.handle_binary(message)
            else:
                reply = await session.handle_text(message)

            if reply is not None:
                await websocket.send(json.dumps(reply))
    except websockets.exceptions.ConnectionClosed:
        LOGGER.info("Connection closed %s", connection_id)
    except (RuntimeError, ValueError, OSError) as exc:
        LOGGER.exception("Unhandled error on connection %s: %s", connection_id, exc)


async def run_daemon(host: str, port: int, model: VibevoiceModel) -> None:
    """Start the WebSocket server and run until cancelled."""

    def _make_handler(m: VibevoiceModel) -> Any:
        async def handler(websocket: Any) -> None:
            await _handle_connection(websocket, m)

        return handler

    async with websockets.serve(_make_handler(model), host, port):
        LOGGER.info("[vibevoicedaemon] listening on ws://%s:%d", host, port)
        await asyncio.Future()  # run forever
