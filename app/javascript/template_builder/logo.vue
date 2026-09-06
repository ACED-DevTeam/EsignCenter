<template>
  <!-- The EsignCenter mark, identical geometry to app/views/shared/_logo.html.erb
       (the navbar and marketing header use the same paths): the builder header
       is our product surface, and DocuSeal is a trademark we do not use as our
       own brand. DocuSeal attribution lives in shared/_powered_by, not here. -->
  <svg
    height="40"
    width="40"
    viewBox="0 0 180 180"
    role="img"
    aria-label="EsignCenter"
    xmlns="http://www.w3.org/2000/svg"
  >
    <rect
      x="8"
      y="8"
      width="164"
      height="164"
      rx="36"
      fill="#4F46E5"
    />
    <path
      d="M 50 94 L 78 121 L 132 60"
      stroke="#FFFFFF"
      stroke-width="15"
      stroke-linecap="round"
      stroke-linejoin="round"
      fill="none"
    />
    <path
      d="M 46 140 C 76 151, 104 151, 134 140"
      stroke="#FFFFFF"
      stroke-width="8"
      stroke-linecap="round"
      fill="none"
      opacity="0.85"
    />
  </svg>
</template>

<script>
export default {
  name: 'ProjectLogo'
}
</script>
