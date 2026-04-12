/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,ts,jsx,tsx}'],
  theme: {
    extend: {
      colors: {
        brand: {
          50:  '#fef3f2',
          100: '#fde5e3',
          200: '#fdcfcc',
          300: '#f9aaa5',
          400: '#f47a71',
          500: '#ea5046',
          600: '#d73328',
          700: '#b5271e',
          800: '#96241c',
          900: '#7c241e',
          950: '#430e0b',
        },
      },
    },
  },
  plugins: [],
};
