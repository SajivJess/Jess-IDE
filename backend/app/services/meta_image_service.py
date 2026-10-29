import base64
import logging
import uuid
from pathlib import Path
from typing import Any, Dict, Optional
import httpx

from app.core.config import settings

logger = logging.getLogger("jess_backend")

# 1x1 transparent PNG fallback if simulated
_SIMULATED_PNG_BASE64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
)


class MetaImageService:
    """Service for generating and refining UI design suggestions using Muse Image (muse-image-1.0).
    
    Generates visual mockups from user descriptions and design requirements.
    Results are cached securely and presented as design previews without altering workspace code.
    """

    def __init__(self) -> None:
        self.cache_dir = Path("workspaces_data/ui_suggestions")
        self.cache_dir.mkdir(parents=True, exist_ok=True)

    async def generate_ui_suggestion(
        self,
        prompt: str,
        project_id: Optional[str] = None,
        reference_image_base64: Optional[str] = None,
    ) -> Dict[str, Any]:
        """Generate a UI design suggestion mockup using Meta Model API.
        
        Args:
            prompt: User description of the desired UI/UX component or redesign.
            project_id: Contextual project ID for scoped caching.
            reference_image_base64: Optional base64-encoded reference screenshot.
            
        Returns:
            Dictionary with image_id, image_url, prompt, model, and metadata.
        """
        api_key = settings.MODEL_API_KEY
        base_url = settings.META_MODEL_BASE_URL.rstrip("/")
        model_id = settings.META_IMAGE_MODEL_ID

        if not prompt or not prompt.strip():
            raise ValueError("Prompt description cannot be empty.")

        clean_prompt = prompt.strip()
        enhanced_prompt = (
            f"High-fidelity UI/UX design mockup: {clean_prompt}. "
            "Clean layout, sleek modern aesthetics, dark mode accents, mobile application interface."
        )

        image_id = str(uuid.uuid4())
        image_filename = f"{image_id}.png"
        image_path = self.cache_dir / image_filename

        # Safe fallback if API key is not configured or in offline mode
        if not api_key:
            logger.info("[MetaImage] MODEL_API_KEY not set. Generating mock UI suggestion preview.")
            mockup_asset = Path(__file__).resolve().parent.parent / "assets" / "simulated_ui_mockup.png"
            if mockup_asset.exists():
                png_bytes = mockup_asset.read_bytes()
                b64_str = base64.b64encode(png_bytes).decode("ascii")
            else:
                png_bytes = base64.b64decode(_SIMULATED_PNG_BASE64)
                b64_str = _SIMULATED_PNG_BASE64
            image_path.write_bytes(png_bytes)
            return {
                "id": image_id,
                "prompt": f"[Simulated Mockup] {clean_prompt}",
                "model": model_id,
                "status": "simulated",
                "image_filename": image_filename,
                "image_data_uri": f"data:image/png;base64,{b64_str}",
                "note": "Design preview in Simulation Mode. Configure MODEL_API_KEY for live Meta Model API generation.",
            }

        url = f"{base_url}/images/generations"
        headers = {
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        }

        payload: Dict[str, Any] = {
            "model": model_id,
            "prompt": enhanced_prompt,
            "n": 1,
            "size": "1024x1024",
            "response_format": "b64_json",
        }

        logger.info(f"[MetaImage] Generating UI suggestion with model '{model_id}' for prompt: '{clean_prompt[:40]}'")

        async with httpx.AsyncClient(timeout=90.0) as client:
            try:
                response = await client.post(url, headers=headers, json=payload)
                if response.status_code != 200:
                    err_msg = response.text[:300]
                    logger.error(f"[MetaImage] Request failed: status {response.status_code} - {err_msg}")
                    raise RuntimeError(f"UI suggestion service error ({response.status_code}): {err_msg}")

                res_json = response.json()
                data_list = res_json.get("data", [])
                if not data_list:
                    raise RuntimeError("No image data returned from image generation service.")

                item = data_list[0]
                b64_data = item.get("b64_json")
                if b64_data:
                    png_bytes = base64.b64decode(b64_data)
                    image_path.write_bytes(png_bytes)
                    data_uri = f"data:image/png;base64,{b64_data}"
                else:
                    # If provider returned URL instead of b64_json
                    image_url_remote = item.get("url", "")
                    data_uri = image_url_remote

                return {
                    "id": image_id,
                    "prompt": clean_prompt,
                    "model": model_id,
                    "status": "generated",
                    "image_filename": image_filename,
                    "image_data_uri": data_uri,
                    "note": "Design proposal generated by Muse Image 1.0. Review and instruct Muse Spark to code it.",
                }

            except httpx.TimeoutException:
                logger.error("[MetaImage] Request timed out while generating UI suggestion.")
                raise TimeoutError("UI suggestion service timed out.")
            except Exception as e:
                logger.error(f"[MetaImage] Error generating UI suggestion: {e}")
                raise


meta_image_service = MetaImageService()
