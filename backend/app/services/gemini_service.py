import json
import logging
from typing import Any, Dict, List, Optional
import httpx

from app.core.config import settings

logger = logging.getLogger("jess_backend")


class GeminiClient:
    """Client for interacting with Google Gemini API for chat and intent routing."""

    def __init__(
        self,
        api_key: Optional[str] = None,
        model: Optional[str] = None,
        base_url: Optional[str] = None,
    ) -> None:
        self.api_key = api_key
        self.model = model
        self.base_url = (base_url or settings.GEMINI_API_BASE).rstrip("/")

    @property
    def current_api_key(self) -> Optional[str]:
        return self.api_key or settings.GEMINI_API_KEY

    @property
    def current_model(self) -> str:
        return self.model or settings.GEMINI_MODEL

    @property
    def is_configured(self) -> bool:
        """Check if Gemini API key is configured."""
        key = self.current_api_key
        return bool(key and key.strip())

    async def classify_intent(
        self,
        prompt: str,
        project_name: str = "",
        project_description: Optional[str] = None,
    ) -> Optional[str]:
        """Classify user intent using Gemini.
        
        Returns one of:
          - CONVERSATION
          - PROJECT_QUESTION
          - CODING_INSTRUCTION
          - AMBIGUOUS
        Or None if the call fails or Gemini is not configured.
        """
        if not self.is_configured:
            return None

        system_instruction = (
            "You are an intent classification engine for an AI coding assistant. "
            "Classify the user's message into exactly ONE of the following 4 categories:\n"
            "1. CONVERSATION: Greetings (e.g. 'hey', 'hello', 'hi', 'how are you', 'good morning'), "
            "social pleasantries, casual conversation, general questions about you or programming concepts.\n"
            "2. PROJECT_QUESTION: Questions asking to explain, inspect, find, or clarify code or project architecture "
            "(e.g. 'Explain the API client', 'What does this project do?', 'How does auth work?'), WITHOUT requesting code edits.\n"
            "3. CODING_INSTRUCTION: Clear, actionable instructions to modify files, write code, implement features, "
            "run tests, refactor, or fix bugs (e.g. 'Add exponential backoff retry logic to the API client', 'Create a new model').\n"
            "4. AMBIGUOUS: Vague, incomplete requests where the action is unclear (e.g. 'fix it', 'update code', 'do something', 'run').\n\n"
            "Respond ONLY with a JSON object: {\"intent\": \"CONVERSATION\" | \"PROJECT_QUESTION\" | \"CODING_INSTRUCTION\" | \"AMBIGUOUS\"}"
        )

        user_content = f"Project: {project_name}\nDescription: {project_description or 'None'}\n\nUser Message: {prompt}"

        url = f"{self.base_url}/models/{self.current_model}:generateContent?key={self.current_api_key}"
        payload = {
            "contents": [
                {
                    "role": "user",
                    "parts": [{"text": f"{system_instruction}\n\n{user_content}"}],
                }
            ],
            "generationConfig": {
                "temperature": 0.0,
                "responseMimeType": "application/json",
            },
        }

        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                res = await client.post(url, json=payload)
                if res.status_code != 200:
                    logger.warning(
                        f"Gemini intent classification failed HTTP {res.status_code}: {res.text}"
                    )
                    return None
                data = res.json()
                text = (
                    data.get("candidates", [{}])[0]
                    .get("content", {})
                    .get("parts", [{}])[0]
                    .get("text", "")
                    .strip()
                )
                parsed = json.loads(text)
                intent = parsed.get("intent", "").upper().strip()
                if intent in {
                    "CONVERSATION",
                    "PROJECT_QUESTION",
                    "CODING_INSTRUCTION",
                    "AMBIGUOUS",
                }:
                    return intent
        except Exception as e:
            logger.warning(f"Error calling Gemini for intent classification: {e}")

        return None

    async def generate_chat_reply(
        self,
        prompt: str,
        project_name: str = "",
        project_description: Optional[str] = None,
        intent: str = "CONVERSATION",
        history: Optional[List[Dict[str, str]]] = None,
    ) -> Optional[str]:
        """Generate a natural conversational response using Gemini."""
        if not self.is_configured:
            return None

        system_prompt = (
            f"You are Jess, an intelligent conversational AI programming assistant for the project '{project_name}'. "
            f"Project description: {project_description or 'No description provided.'}\n\n"
            "Guidelines:\n"
            "- Be concise, friendly, helpful, and direct.\n"
            "- If the user greeted you, greet them warmly and ask what they would like to work on.\n"
            "- If answering a question about the project, explain clearly without pretending you modified files.\n"
            "- If the request is ambiguous, politely ask clarifying questions to understand what code changes they want.\n"
            "- Do NOT generate code diffs or claim you executed commands unless you actually did."
        )

        contents = []
        if history:
            for h in history[-4:]:
                contents.append(
                    {
                        "role": "user" if h.get("role") == "user" else "model",
                        "parts": [{"text": h.get("content", "")}],
                    }
                )

        contents.append(
            {
                "role": "user",
                "parts": [{"text": f"System context: {system_prompt}\n\nUser: {prompt}"}],
            }
        )

        url = f"{self.base_url}/models/{self.current_model}:generateContent?key={self.current_api_key}"
        payload = {
            "contents": contents,
            "generationConfig": {
                "temperature": 0.7,
                "maxOutputTokens": 800,
            },
        }

        try:
            async with httpx.AsyncClient(timeout=15.0) as client:
                res = await client.post(url, json=payload)
                if res.status_code == 200:
                    data = res.json()
                    return (
                        data.get("candidates", [{}])[0]
                        .get("content", {})
                        .get("parts", [{}])[0]
                        .get("text", "")
                        .strip()
                    )
                logger.warning(
                    f"Gemini reply generation failed HTTP {res.status_code}: {res.text}"
                )
        except Exception as e:
            logger.warning(f"Error calling Gemini for chat reply: {e}")

        return None


# Global singleton instance
gemini_client = GeminiClient()
