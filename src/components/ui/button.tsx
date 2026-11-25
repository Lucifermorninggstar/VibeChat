import type { ButtonHTMLAttributes } from 'react';

// Small shadcn-style primitive; variants stay in the app's design system.
export function Button({ className = '', ...props }: ButtonHTMLAttributes<HTMLButtonElement>) {
  return <button className={`button ${className}`} {...props} />;
}
