# React Notes


## General
- **Use Typescript** for react components.
- **Use the `strict` compiler option** to avoid type coercion.
- **Use `null` instead of `undefined`** to avoid type coercion.
- Always format your code before committing it.


## Imports
- Keep imports sorted and grouped by type.
- Group imports by type, first external imports, then internal imports, and finally same folder imports.
    - External imports: `import React from 'react'`
    - Internal imports: `import { Button } from 'src/components/Button'`
    - Same folder imports: `import { Button } from './Button'`
- **Use absolute imports** instead of relative imports : `import { Button } from 'src/components/Button'` instead of `import { Button } from '../../components/Button'`.


## Components
- **Use functional components** instead of class components.
- **Use hooks** instead of class components.
- **Use React.memo** to avoid unnecessary re-renders.
- **Use React.lazy** to lazy load components.
- **Use React.Suspense** to lazy load components.
- **Use React.Fragment** to avoid unnecessary divs.
- **Use React.forwardRef** to forward refs to components.
- **Don't use React.createContext** to create contexts, use the `useContext` hook instead.
- **Deconstruct props** to avoid repeating `props` in the component.
- **Don't use index for keys on lists** use a unique id instead.
- **Don't create components inside other components** create them outside and import them.