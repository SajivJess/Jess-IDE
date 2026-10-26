import re
import logging
from enum import Enum
from typing import Dict, List, Optional, Tuple

from app.core.config import settings
from app.services.gemini_service import gemini_client

logger = logging.getLogger("jess_backend")


class MessageIntent(str, Enum):
    """Categorized intent of a user conversation message."""

    CONVERSATION = "CONVERSATION"
    PROJECT_QUESTION = "PROJECT_QUESTION"
    CODING_INSTRUCTION = "CODING_INSTRUCTION"
    AMBIGUOUS = "AMBIGUOUS"


# Semantic patterns for deterministic fallback classification
_GREETING_PATTERN = re.compile(
    r"^\s*(hey|hi|hello|howdy|yo|sup|hiya|greetings|good\s+(morning|afternoon|evening|day))[\s\.,!\?]*$",
    re.IGNORECASE,
)

_CASUAL_CHAT_PATTERN = re.compile(
    r"^\s*(how\s+are\s+you|who\s+are\s+you|what\s+is\s+your\s+name|what\s+can\s+you\s+do|thanks|thank\s+you|cool|nice|ok|okay)[\s\.,!\?]*$",
    re.IGNORECASE,
)

_QUESTION_PATTERNS = [
    re.compile(r"^\s*(explain|describe|summarize|tell\s+me\s+about)\s+(the\s+)?(.+)", re.IGNORECASE),
    re.compile(r"^\s*(what\s+is|what\s+are|what\s+does|where\s+is|where\s+are|how\s+does|how\s+do)\s+(.+)", re.IGNORECASE),
    re.compile(r"^\s*(can\s+you\s+explain|could\s+you\s+explain)\s+(.+)", re.IGNORECASE),
]

_AMBIGUOUS_PATTERNS = [
    re.compile(r"^\s*(fix\s+it|fix\s+this|make\s+it\s+work|do\s+it|update\s+it|change\s+it|help|help\s+me)[\s\.,!\?]*$", re.IGNORECASE),
    re.compile(r"^\s*(make\s+changes|run\s+something|code\s+something|do\s+something)[\s\.,!\?]*$", re.IGNORECASE),
]

_CODING_ACTION_PATTERNS = [
    re.compile(r"\b(add|create|implement|write|build|setup|generate)\b\s+(.+)", re.IGNORECASE),
    re.compile(r"\b(refactor|modify|update|rewrite|migrate|restructure|repair)\b\s+(.+)", re.IGNORECASE),
    re.compile(r"\b(fix|resolve|patch|debug|diagnose)\b.*?\b(bug|error|issue|problem|failure|test|retry|timeout|exception)\b", re.IGNORECASE),
    re.compile(r"\b(run|execute|rerun)\b.*?\b(tests?|pytest|unittest|build|script|command|check|migrations?)\b", re.IGNORECASE),
    re.compile(r"\b(inspect|examine|analyze|check)\b.*?\b([a-zA-Z0-9_\-\./]+\.(py|js|ts|dart|json|ya?ml))\b", re.IGNORECASE),
    re.compile(r"\b(delete|remove)\s+(the\s+)?(.+)", re.IGNORECASE),
]


class IntentRouter:
    """Classifies user intent and routes between conversational replies and coding runs."""

    @classmethod
    async def classify(
        cls,
        prompt: str,
        project_name: str = "",
        project_description: Optional[str] = None,
    ) -> MessageIntent:
        """Classify message into an intent.
        
        Attempts Gemini LLM classification first when configured; falls back safely
        to deterministic rule-based classification if unconfigured or on failure.
        CRITICAL SAFETY RULE: Never defaults to CODING_INSTRUCTION on failure.
        """
        trimmed = prompt.strip()
        if not trimmed:
            return MessageIntent.AMBIGUOUS

        # 1. Try Gemini classifier if configured
        if gemini_client.is_configured:
            try:
                llm_intent = await gemini_client.classify_intent(
                    trimmed, project_name=project_name, project_description=project_description
                )
                if llm_intent:
                    return MessageIntent(llm_intent)
            except Exception as e:
                logger.warning(f"Gemini intent classification raised error: {e}. Falling back safely.")

        # 2. Deterministic rule-based classification
        return cls._classify_rules(trimmed)

    @classmethod
    def _classify_rules(cls, text: str) -> MessageIntent:
        """Deterministic, rule-based classification policy."""
        lowered = text.lower().strip()

        # A. Greetings
        if _GREETING_PATTERN.match(lowered):
            return MessageIntent.CONVERSATION

        # B. Casual pleasantries / small talk
        if _CASUAL_CHAT_PATTERN.match(lowered):
            return MessageIntent.CONVERSATION

        # C. Ambiguous requests (e.g. "fix it", "help")
        for pat in _AMBIGUOUS_PATTERNS:
            if pat.match(lowered):
                return MessageIntent.AMBIGUOUS

        # D. Questions about code or project (e.g. "Explain the API client", "Where is auth?")
        for pat in _QUESTION_PATTERNS:
            if pat.match(lowered):
                # Ensure it's not actually an imperative instruction phrased with question mark
                is_coding_imperative = any(cpat.search(lowered) for cpat in _CODING_ACTION_PATTERNS)
                if not is_coding_imperative:
                    return MessageIntent.PROJECT_QUESTION

        # E. Explicit coding instructions (e.g. "Add exponential backoff retry logic to the API client")
        for pat in _CODING_ACTION_PATTERNS:
            if pat.search(lowered):
                return MessageIntent.CODING_INSTRUCTION

        # F. Questions ending with '?' without coding imperatives
        if lowered.endswith("?") and not any(pat.search(lowered) for pat in _CODING_ACTION_PATTERNS):
            return MessageIntent.PROJECT_QUESTION

        # G. Very short vague inputs (< 3 words) without explicit coding verbs -> AMBIGUOUS
        words = lowered.split()
        if len(words) <= 2:
            return MessageIntent.AMBIGUOUS

        # H. Default safe fall-closed: do NOT start coding run!
        return MessageIntent.AMBIGUOUS

    @classmethod
    async def generate_conversational_reply(
        cls,
        intent: MessageIntent,
        prompt: str,
        project_name: str = "",
        project_description: Optional[str] = None,
        history: Optional[List[Dict[str, str]]] = None,
    ) -> str:
        """Generate a natural conversational response for non-coding intents."""
        # 1. Try Gemini generation if configured
        if gemini_client.is_configured:
            try:
                reply = await gemini_client.generate_chat_reply(
                    prompt=prompt,
                    project_name=project_name,
                    project_description=project_description,
                    intent=intent.value,
                    history=history,
                )
                if reply and reply.strip():
                    return reply.strip()
            except Exception as e:
                logger.warning(f"Gemini reply generation error: {e}. Falling back to template.")

        # 2. High-quality deterministic responses
        p_name = project_name or "your project"
        lowered = prompt.lower().strip()

        if intent == MessageIntent.CONVERSATION:
            if "how are you" in lowered:
                return f"I'm doing great, thank you! 😊 Ready to help you build and inspect **{p_name}**. What are we working on today?"
            elif any(g in lowered for g in ["thank", "thanks"]):
                return "You're very welcome! Let me know whenever you'd like to work on code or inspect changes."
            elif any(g in lowered for g in ["who are you", "what can you do"]):
                return (
                    f"I am Jess, your conversational AI coding assistant for **{p_name}**! "
                    "You can chat with me, ask questions about your codebase, or give me explicit instructions "
                    "to inspect files, write features, run tests, and propose code changes."
                )
            else:
                return f"Hey! 👋 What are we working on today in **{p_name}**?"

        elif intent == MessageIntent.PROJECT_QUESTION:
            desc_clause = f" ({project_description})" if project_description else ""
            return (
                f"**{p_name}**{desc_clause} is configured as a remote development workspace. "
                f"You asked: *\"{prompt.strip()}\"*\n\n"
                "I can inspect the workspace files, review git status, and explain any component without "
                "modifying your code. To see specific implementation details, you can also browse the "
                "**Workspace** tab or ask me to check a specific file."
            )

        elif intent == MessageIntent.AMBIGUOUS:
            return (
                f"Could you please clarify what you'd like me to do in **{p_name}**? "
                "For example, you can ask me to:\n"
                "• *\"Add exponential backoff retry logic to the API client\"*\n"
                "• *\"Inspect project structure and git status\"*\n"
                "• *\"Run tests and verify project\"*\n"
                "• Or ask an exploratory question about your code."
            )

        # Fallback
        return f"How can I assist you with **{p_name}** today?"
