"""Recognize literal writing requests without interpreting their contents as commands."""
import re


def dictated_text(request):
    match=re.fullmatch(r'(?:please\s+)?(?:type|write)\s+(?:(?:exactly|the following)\s*[:,]?\s*)?(.+)',request.strip(),re.I|re.S)
    if not match:return None
    value=match[1].strip()
    quoted=re.fullmatch(r'["“](.+)["”](?:\s+(?:in|into)\s+(?:(?:this|the|the current|the open)\s+)?(?:document|file|text document))?[.!]?',value,re.S|re.I)
    if quoted:return quoted[1]
    # Composition, transformations, and multiple actions stay with the model.
    if re.match(r'me\s+',value,re.I):return None
    if re.match(r'(?:a|an|the|some|one|two|three|four|five|\d+)\s+(?:(?:short|long|little|brief|new|friendly|professional)\s+)*(?:stor(?:y|ies)|poems?|emails?|letters?|paragraphs?|sentences?|essays?|messages?|reply|summary|articles?|list|code)\b',value,re.I):return None
    if re.match(r'(?:something|about)\b|(?:it|that|this|them)(?:[.!?]?$|\s+(?:down|here|there|in|as|into)\b)',value,re.I):return None
    if re.search(r'\b(?:then|and)\s+(?:open|close|save|send|delete|click|go|launch|switch)\b',value,re.I):return None
    if re.search(r'\s+(?:in|into)\s+(?:TextEdit|Notes|Word|Pages|the document|this document)\b',value,re.I):return None
    return value if 0<len(value)<=4000 else None
